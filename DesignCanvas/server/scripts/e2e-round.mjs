// End-to-end proof of the round lifecycle, Node only, no devices attached
// (Task 13). Plays both hardware ends against a real built daemon:
//
//   --http daemon   : the same process a running Mac app supervises.
//   --channel proc  : the same process Claude Code spawns via .mcp.json.
//
// This script is the engine AND the iPad AND Claude Code, all at once:
//   - It opens GET /v1/rounds/stream the way the Mac engine does, to observe
//     `round.updated` events (queued -> sent -> applied) live.
//   - It attaches real `--channel` children through the MCP SDK's
//     StdioClientTransport, exactly as Claude Code would, and reads the
//     `notifications/claude/channel` notifications and calls the
//     `design_canvas_reply` tool back over the same connection.
//   - It POSTs captures and annotations over HTTP the way the Mac engine's
//     DaemonClient does, standing in for the iPad's sketch.
//
// Three scenarios, one shared daemon + temp store, run in order:
//
//   round    - a full round for device ipad-A: queued -> sent (one channel
//              notification) -> applied (via design_canvas_reply with a PR
//              URL), each transition observed on the rounds stream, then
//              confirmed via GET /v1/rounds?device=ipad-A.
//   backlog  - two annotations posted with no channel attached, then a
//              channel attaches and must notify both, in creation order, at
//              least ~1s apart (the daemon's backlog replay throttle).
//   reconnect snapshot - a second device, ipad-B: a reply recorded on the
//              daemon while nothing was subscribed to the rounds stream must
//              still show up in a fresh GET /v1/rounds?device=ipad-B, and
//              that snapshot must not leak ipad-A's rounds.
//
// Each scenario prints one `ok`/`FAIL` line and the process exits non-zero
// if any scenario failed. A scenario's own failure does not stop the others
// from running.
//
// Timeout handling mirrors scripts/channel-harness.mjs: the whole flow
// (`runAll`) races a rejection that fires when the watchdog aborts an
// AbortController, so a real hang REJECTS the race instead of calling
// process.exit() from inside the timer (which would skip cleanup). The
// single try/catch/finally below is the one and only cleanup path, on
// success, a failed assertion, or a timeout. `E2E_TIMEOUT_MS` overrides the
// default 90s overall timeout.

import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const OVERALL_TIMEOUT_MS = Number(process.env.E2E_TIMEOUT_MS ?? 90_000);
const SCENARIO_NAMES = ['round', 'backlog', 'reconnect snapshot'];

const root = fileURLToPath(new URL('../', import.meta.url)); // DesignCanvas/server/
const entry = 'dist/index.js';
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzc4wAAAABJRU5ErkJggg==',
  'base64',
);

const storeDir = await mkdtemp(join(tmpdir(), 'design-canvas-e2e-store-'));
const logPath = join(storeDir, 'server.log');
const port = String(await findFreePort());
const childEnv = {
  ...process.env,
  SERVER_PORT: port,
  DESIGN_CANVAS_STORE_DIR: storeDir,
  DESIGN_CANVAS_LOG_PATH: logPath,
};

let daemon = null;
// Backstop: any --channel child pid currently attached. Each scenario adds
// its own pid on attach and removes it on a clean close(); this set only
// matters for the crash/timeout path where a scenario's own cleanup never ran.
const channelPids = new Set();
const results = new Map(); // name -> { ok, detail }
let fatalError = null;

const controller = new AbortController();
const watchdog = setTimeout(() => {
  controller.abort(new Error(`Timed out after ${OVERALL_TIMEOUT_MS}ms`));
}, OVERALL_TIMEOUT_MS);

try {
  await Promise.race([runAll(controller.signal), abortRejection(controller.signal)]);
} catch (error) {
  fatalError = error;
  process.stderr.write(`e2e-round: ${error?.stack ?? error}\n`);
} finally {
  clearTimeout(watchdog);
  for (const name of SCENARIO_NAMES) {
    if (!results.has(name)) {
      results.set(name, {
        ok: false,
        detail: fatalError ? `did not run: ${errorMessage(fatalError)}` : 'did not run',
      });
    }
  }
  killChild(daemon);
  for (const pid of channelPids) killByPid(pid);
  await rm(storeDir, { recursive: true, force: true });
}

for (const name of SCENARIO_NAMES) {
  const result = results.get(name);
  process.stdout.write(result.ok ? `ok - ${name}\n` : `FAIL - ${name}: ${result.detail}\n`);
}
process.exitCode = [...results.values()].some((result) => !result.ok) ? 1 : 0;
// Force prompt termination now that cleanup has fully run (daemon and any
// channel children killed, temp dir removed). Without this, an abandoned
// runAll() -- the loser of the race above -- could keep scheduling timers and
// hold the event loop open well past its own inner timeouts.
process.exit(process.exitCode);

/** Rejects once `signal` aborts, with the abort's reason. Never resolves. */
function abortRejection(signal) {
  return new Promise((_resolve, reject) => {
    const onAbort = () => reject(signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason)));
    if (signal.aborted) {
      onAbort();
      return;
    }
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

async function runAll(signal) {
  await build();

  daemon = spawn(process.execPath, [entry, '--http'], {
    cwd: root,
    env: childEnv,
    stdio: ['ignore', 'inherit', 'pipe'],
  });
  let daemonStderr = '';
  daemon.stderr?.setEncoding('utf8');
  daemon.stderr?.on('data', (chunk) => {
    daemonStderr += chunk;
  });
  daemon.on('exit', (code) => {
    if (code !== null && code !== 0) {
      process.stderr.write(`daemon exited early with code ${code}\n${daemonStderr}\n`);
    }
  });
  await waitForHealth(signal);

  const priorAnnotationIds = [];

  await runScenario('round', async () => {
    const { annotationId } = await scenarioRound(signal);
    priorAnnotationIds.push(annotationId);
  });

  await runScenario('backlog', async () => {
    const { annotationIds } = await scenarioBacklog(signal);
    priorAnnotationIds.push(...annotationIds);
  });

  await runScenario('reconnect snapshot', async () => {
    await scenarioReconnectSnapshot(signal, priorAnnotationIds);
  });
}

/** Runs one scenario, recording ok/FAIL without letting its failure stop the others. */
async function runScenario(name, fn) {
  try {
    await fn();
    results.set(name, { ok: true });
  } catch (error) {
    results.set(name, { ok: false, detail: errorMessage(error) });
  }
}

// ---------------------------------------------------------------------------
// Scenario: round
// ---------------------------------------------------------------------------

async function scenarioRound(signal) {
  const stream = await watchRoundsStream(signal);
  const channel = await attachChannel(signal);
  try {
    const annotationId = await createAnnotation(
      { id: 'ipad-A', name: 'iPad A' },
      { zoomRect: { x: 0.25, y: 0.1, w: 0.5, h: 0.4 }, note: { text: 'Make the primary button larger.' } },
      signal,
    );

    await waitFor(
      () => stream.events.some((event) => event.annotationId === annotationId && event.status === 'queued'),
      5000,
      'round.updated queued',
      signal,
    );
    await waitFor(
      () => stream.events.some((event) => event.annotationId === annotationId && event.status === 'sent'),
      8000,
      'round.updated sent',
      signal,
    );
    const queuedIndex = stream.events.findIndex(
      (event) => event.annotationId === annotationId && event.status === 'queued',
    );
    const sentIndex = stream.events.findIndex(
      (event) => event.annotationId === annotationId && event.status === 'sent',
    );
    if (!(queuedIndex < sentIndex)) {
      throw new Error(`expected queued before sent on the rounds stream, got indices ${queuedIndex}, ${sentIndex}`);
    }

    await waitFor(() => channel.notifications.length >= 1, 8000, 'channel notification', signal);
    // Allow a beat for any (unwanted) duplicates to surface before asserting "exactly one".
    await delay(300, undefined, { signal });
    if (channel.notifications.length !== 1) {
      throw new Error(
        `expected exactly 1 channel notification, got ${channel.notifications.length}: ` +
          JSON.stringify(channel.notifications.map((entry) => entry.notification)),
      );
    }
    const notification = channel.notifications[0].notification;
    if (notification.params?.meta?.annotation_id !== annotationId) {
      throw new Error(`channel notification is for the wrong annotation: ${JSON.stringify(notification)}`);
    }

    const prUrl = 'https://github.com/example/repo/pull/1';
    const reply = await channel.client.callTool({
      name: 'design_canvas_reply',
      arguments: {
        annotation_id: annotationId,
        status: 'applied',
        message: 'Made the primary button larger.',
        pr_url: prUrl,
      },
    });
    if (reply.isError) {
      throw new Error(`design_canvas_reply returned isError: ${JSON.stringify(reply)}`);
    }

    await waitFor(
      () => stream.events.some((event) => event.annotationId === annotationId && event.status === 'applied'),
      8000,
      'round.updated applied',
      signal,
    );

    const { rounds } = await getJson(`/v1/rounds?device=ipad-A`, signal);
    const round = rounds.find((entry) => entry.annotationId === annotationId);
    if (!round) {
      throw new Error(`annotation ${annotationId} missing from /v1/rounds?device=ipad-A`);
    }
    if (round.status !== 'applied') {
      throw new Error(`expected /v1/rounds status applied, got ${round.status}`);
    }
    if (round.prUrl !== prUrl) {
      throw new Error(`expected /v1/rounds prUrl ${prUrl}, got ${round.prUrl}`);
    }

    return { annotationId };
  } finally {
    await channel.close();
    await stream.close();
  }
}

// ---------------------------------------------------------------------------
// Scenario: backlog
// ---------------------------------------------------------------------------

async function scenarioBacklog(signal) {
  const device = { id: 'ipad-A', name: 'iPad A' };
  // Two annotations posted with no channel attached at all.
  const firstId = await createAnnotation(device, {}, signal);
  const secondId = await createAnnotation(device, {}, signal);

  const channel = await attachChannel(signal);
  try {
    await waitFor(() => channel.notifications.length >= 2, 10_000, 'two backlog notifications', signal);
    // Allow a beat for any (unwanted) duplicates/extra deliveries to surface.
    await delay(300, undefined, { signal });
    if (channel.notifications.length !== 2) {
      throw new Error(
        `expected exactly 2 backlog notifications, got ${channel.notifications.length}: ` +
          JSON.stringify(channel.notifications.map((entry) => entry.notification)),
      );
    }

    const ids = channel.notifications.map((entry) => entry.notification.params?.meta?.annotation_id);
    if (ids[0] !== firstId || ids[1] !== secondId) {
      throw new Error(
        `expected backlog notifications in creation order [${firstId}, ${secondId}], got ${JSON.stringify(ids)}`,
      );
    }

    // Resolution: allow scheduler slop the other way only (>= 900ms, not a
    // strict >= 1000ms), since the daemon throttles backlog replay to 1/s.
    const gapMs = channel.notifications[1].at - channel.notifications[0].at;
    if (gapMs < 900) {
      throw new Error(`expected backlog notifications >= 900ms apart, got ${gapMs}ms`);
    }

    return { annotationIds: [firstId, secondId] };
  } finally {
    await channel.close();
  }
}

// ---------------------------------------------------------------------------
// Scenario: reconnect snapshot
// ---------------------------------------------------------------------------

async function scenarioReconnectSnapshot(signal, priorAnnotationIds) {
  // No /v1/rounds/stream subscriber and no --channel attached at any point in
  // this scenario: the reply below is recorded directly against the daemon,
  // as design_canvas_reply would, with nobody watching the live feed.
  const annotationId = await createAnnotation({ id: 'ipad-B', name: 'iPad B' }, {}, signal);
  await postJson(
    `/v1/annotations/${annotationId}/reply`,
    { status: 'applied', message: 'Adjusted the layout.' },
    signal,
  );

  const { rounds } = await getJson(`/v1/rounds?device=ipad-B`, signal);
  const round = rounds.find((entry) => entry.annotationId === annotationId);
  if (!round) {
    throw new Error(
      'the reply recorded while no rounds stream was open is missing from the /v1/rounds?device=ipad-B snapshot',
    );
  }
  if (round.status !== 'applied') {
    throw new Error(`expected the snapshot round status to be applied, got ${round.status}`);
  }

  const leaked = rounds.filter((entry) => priorAnnotationIds.includes(entry.annotationId));
  if (leaked.length > 0) {
    throw new Error(`/v1/rounds?device=ipad-B leaked rounds belonging to another device: ${JSON.stringify(leaked)}`);
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

async function createCapture(signal) {
  const capture = await postJson(
    '/v1/captures',
    { screenshotBase64: png.toString('base64'), viewport: { w: 800, h: 600 } },
    signal,
  );
  return String(capture.captureId);
}

async function createAnnotation(device, overrides, signal) {
  const sourceCaptureId = await createCapture(signal);
  const body = {
    compositeBase64: png.toString('base64'),
    sketchBase64: png.toString('base64'),
    sourceCaptureId,
    viewport: { w: 800, h: 600 },
    zoomRect: null,
    device,
    ...overrides,
  };
  const annotation = await postJson('/v1/annotations', body, signal);
  return String(annotation.annotationId);
}

/** Opens GET /v1/rounds/stream the way the Mac engine does and collects `round.updated` events. */
async function watchRoundsStream(signal) {
  const streamController = new AbortController();
  const onOuterAbort = () => streamController.abort();
  signal.addEventListener('abort', onOuterAbort, { once: true });
  const response = await fetch(`http://127.0.0.1:${port}/v1/rounds/stream`, { signal: streamController.signal });
  if (!response.ok || !response.body) {
    throw new Error(`rounds stream connect failed: ${response.status}`);
  }
  const events = [];
  const pumped = pumpSse(response.body, (data) => events.push(JSON.parse(data)));
  return {
    events,
    async close() {
      signal.removeEventListener('abort', onOuterAbort);
      streamController.abort();
      await pumped.catch(() => {});
    },
  };
}

/** Reads Server-Sent Events frames (`\n\n`-separated) from `body`, calling `onData` with each `data:` line. */
async function pumpSse(body, onData) {
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    for await (const chunk of body) {
      buffer += decoder.decode(chunk, { stream: true });
      let boundary = buffer.indexOf('\n\n');
      while (boundary !== -1) {
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const dataLine = frame.split('\n').find((line) => line.startsWith('data:'));
        if (dataLine) onData(dataLine.slice('data:'.length).trim());
        boundary = buffer.indexOf('\n\n');
      }
    }
  } catch {
    // Aborted by close(), or the daemon went away during cleanup — nothing further to collect.
  }
}

/** Spawns a real `--channel` child through the MCP SDK's StdioClientTransport, as Claude Code would. */
async function attachChannel(signal) {
  const client = new Client({ name: 'design-canvas-e2e', version: '0.0.0' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [entry, '--channel'],
    cwd: root,
    env: childEnv,
    stderr: 'pipe',
  });
  let stderrText = '';
  transport.stderr?.setEncoding('utf8');
  transport.stderr?.on('data', (chunk) => {
    stderrText += chunk;
  });
  const notifications = [];
  // notifications/claude/channel isn't one of the SDK's standard notification
  // schemas, so it only reaches the fallback handler.
  client.fallbackNotificationHandler = async (notification) => {
    if (notification.method === 'notifications/claude/channel') {
      notifications.push({ notification, at: Date.now() });
    }
  };
  await client.connect(transport);
  if (typeof transport.pid === 'number') channelPids.add(transport.pid);

  let closed = false;
  return {
    client,
    notifications,
    async close() {
      if (closed) return;
      closed = true;
      // Capture the pid BEFORE closing: the SDK's transport nulls its process
      // reference once close() runs.
      const pid = transport.pid ?? null;
      await client.close().catch(() => {});
      if (pid !== null) {
        killByPid(pid);
        channelPids.delete(pid);
      }
      if (signal.aborted && stderrText.trim()) {
        process.stderr.write(`--- --channel stderr ---\n${stderrText}\n`);
      }
    },
  };
}

function killChild(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try {
    child.kill('SIGKILL');
  } catch {
    // already gone
  }
}

function killByPid(pid) {
  if (typeof pid !== 'number') return;
  try {
    process.kill(pid, 'SIGKILL');
  } catch {
    // already exited / never spawned
  }
}

async function build() {
  await run('pnpm', ['run', 'build']);
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: 'inherit', env: process.env });
    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} ${args.join(' ')} exited ${code}`));
    });
  });
}

async function waitForHealth(signal) {
  await waitFor(
    async () => {
      try {
        const response = await fetch(`http://127.0.0.1:${port}/v1/health`, { signal });
        return response.ok;
      } catch {
        return false;
      }
    },
    5000,
    'daemon health',
    signal,
  );
}

async function postJson(path, body, signal) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  });
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

async function getJson(path, signal) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, { signal });
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

async function waitFor(predicate, timeoutMs, what, signal) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (signal?.aborted) throw signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason));
    if (await predicate()) return;
    await delay(50, undefined, { signal });
  }
  throw new Error(`Timed out after ${timeoutMs}ms waiting for ${what ?? 'condition'}`);
}

// Ask the OS for an ephemeral port, then release it. There is a small
// bind-after-close race (the port could be taken before the daemon binds), but
// that is an acceptable trade for a test script and far safer than a fixed
// port that collides with stale or concurrent runs.
async function findFreePort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  await new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) reject(error);
      else resolve();
    });
  });
  if (typeof address !== 'object' || address === null) {
    throw new Error('Could not allocate a free TCP port for the e2e script');
  }
  return address.port;
}

/** A short, single-line reason for an `ok`/`FAIL` line (never a multi-line stack). */
function errorMessage(error) {
  const message = error?.message ?? String(error);
  return String(message).split('\n')[0];
}
