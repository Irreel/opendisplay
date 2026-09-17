// Integration harness for the two-process channel topology (Task 7).
//
//   --http daemon   : owns the FS store + HTTP API + loopback SSE stream
//                     (GET /v1/annotations/stream) + loopback claim/served/reply.
//   --channel proc  : Claude-Code-spawned MCP peer. It subscribes to the
//                     daemon's SSE, claims each pending annotation, emits the
//                     `claude/channel` notification over its MCP stdio, then
//                     marks it served. It also exposes the design_canvas_reply
//                     tool, which posts the outcome back to the daemon.
//
// This harness plays Claude Code: it is the MCP CLIENT on the --channel
// child's stdio, spawned through the SDK's StdioClientTransport so a real
// `initialize` handshake happens. It drives the daemon over HTTP, then
// asserts that exactly one channel notification arrives with the v3
// template's Device:/Zoom region: lines, that the annotation's servedAt
// becomes non-null, and — by calling design_canvas_reply back over the same
// MCP connection — that /v1/rounds reports the annotation as applied.
//
// Both children are spawned on a dynamically allocated free SERVER_PORT so the
// harness never collides with a developer's running daemon (or a concurrent
// harness run), and against a fresh temp store + log path.
//
// Timeout handling: the whole flow (`runFlow`) is raced against a rejection
// that fires when the watchdog aborts an AbortController. This means a real
// hang REJECTS the race (instead of calling process.exit() from inside the
// timer, which would skip the try/finally entirely) — so the single
// try/catch/finally below is the one and only cleanup path, on both success
// and any failure, including a timeout. `HARNESS_TIMEOUT_MS` overrides the
// default 60s timeout, for tests of this behavior itself.

import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const OVERALL_TIMEOUT_MS = Number(process.env.HARNESS_TIMEOUT_MS ?? 60_000);
const root = fileURLToPath(new URL('../', import.meta.url)); // DesignCanvas/server/
const entry = 'dist/index.js';
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzc4wAAAABJRU5ErkJggg==',
  'base64',
);

const storeDir = await mkdtemp(join(tmpdir(), 'design-canvas-channel-store-'));
const logPath = join(storeDir, 'server.log');
const port = String(await findFreePort());
const childEnv = {
  ...process.env,
  SERVER_PORT: port,
  DESIGN_CANVAS_STORE_DIR: storeDir,
  DESIGN_CANVAS_LOG_PATH: logPath,
};

let daemon = null;
let client = null;
let channelTransport = null;
let channelStderr = '';
const channelNotifications = [];

// The watchdog only ever aborts the controller — it never touches process
// exit or cleanup directly, so there is exactly one place (below) that does
// either of those things.
const controller = new AbortController();
const watchdog = setTimeout(() => {
  controller.abort(new Error(`Timed out after ${OVERALL_TIMEOUT_MS}ms`));
}, OVERALL_TIMEOUT_MS);

try {
  await Promise.race([runFlow(controller.signal), abortRejection(controller.signal)]);
  process.stdout.write(
    'channel harness: OK (1 notification with Device:/Zoom region:, annotation served, reply recorded and applied)\n',
  );
} catch (error) {
  process.stderr.write(`channel harness FAILED: ${error?.stack ?? error}\n`);
  if (channelStderr.trim()) {
    process.stderr.write(`--- --channel stderr ---\n${channelStderr}\n`);
  }
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  // Tear down BOTH children cleanly, on success, a failed assertion, AND a
  // timeout. Capture the channel child's pid BEFORE closing the client: the
  // SDK's transport nulls its process reference once close() runs, so
  // reading .pid afterward would always be null and killByPid would never
  // actually fire for a channel child that didn't shut down gracefully.
  const channelPid = channelTransport?.pid ?? null;
  await client?.close().catch(() => {});
  killByPid(channelPid);
  killChild(daemon);
  await rm(storeDir, { recursive: true, force: true });
}
// Force prompt termination now that cleanup has fully run (both children
// killed, temp dir removed). Without this, an abandoned runFlow() — the
// loser of the race above, e.g. still polling a now-dead daemon inside
// waitFor — would keep scheduling timers and hold the event loop open for
// up to its own inner timeout (several more seconds) before the process
// actually exited on its own.
process.exit(process.exitCode ?? 0);

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

async function runFlow(signal) {
  // 1. Build (the harness runs against dist/).
  await build();

  // 2. Spawn the --http daemon and wait for health.
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
      process.stderr.write(`daemon exited early with code ${code}\n${daemonStderr}`);
    }
  });
  await waitForHealth(port, signal);

  // 3. Spawn the --channel subscriber. The harness is the MCP client on its
  //    stdio. The MCP SDK's StdioClientTransport spawns the child and performs
  //    the initialize handshake on connect(), exactly as Claude Code would.
  client = new Client({ name: 'design-canvas-channel-harness', version: '0.0.0' });
  channelTransport = new StdioClientTransport({
    command: process.execPath,
    args: [entry, '--channel'],
    cwd: root,
    env: childEnv,
    stderr: 'pipe',
  });
  channelTransport.stderr?.setEncoding('utf8');
  channelTransport.stderr?.on('data', (chunk) => {
    channelStderr += chunk;
  });
  // notifications/claude/channel isn't one of the SDK's standard notification
  // schemas, so it only reaches the fallback handler.
  client.fallbackNotificationHandler = async (notification) => {
    if (notification.method === 'notifications/claude/channel') {
      channelNotifications.push(notification);
    }
  };
  await client.connect(channelTransport);

  // 4. POST a capture then an annotation to the daemon over HTTP.
  const capture = await postJson(port, '/v1/captures', {
    screenshotBase64: png.toString('base64'),
    viewport: { w: 800, h: 600 },
  }, signal);
  const annotation = await postJson(port, '/v1/annotations', {
    compositeBase64: png.toString('base64'),
    sketchBase64: png.toString('base64'),
    sourceCaptureId: capture.captureId,
    viewport: { w: 800, h: 600 },
    zoomRect: { x: 0.25, y: 0.1, w: 0.5, h: 0.4 },
    device: { id: 'harness-ipad', name: 'Harness iPad' },
    note: { text: 'Make the primary button larger.' },
  }, signal);
  const annotationId = String(annotation.annotationId);

  // 5a. Exactly one channel notification arrives at the harness via the
  //     --channel child's MCP stdio.
  await waitFor(() => channelNotifications.length >= 1, 8000, 'channel notification', signal);
  // Allow a beat for any (unwanted) duplicates to surface before asserting "exactly one".
  await delay(500, undefined, { signal });
  if (channelNotifications.length !== 1) {
    throw new Error(
      `Expected exactly 1 channel notification, got ${channelNotifications.length}: ` +
        JSON.stringify(channelNotifications),
    );
  }
  const notification = channelNotifications[0];
  if (notification.params?.meta?.annotation_id !== annotationId) {
    throw new Error(`Channel notification missing annotation id. notification=${JSON.stringify(notification)}`);
  }
  const content = String(notification.params?.content ?? '');
  if (!/^Device: Harness iPad$/m.test(content)) {
    throw new Error(`Channel notification missing Device: line. content=${JSON.stringify(content)}`);
  }
  if (!/^Zoom region: x=0\.250 y=0\.100 w=0\.500 h=0\.400$/m.test(content)) {
    throw new Error(`Channel notification missing Zoom region: line. content=${JSON.stringify(content)}`);
  }

  // 5b. The annotation's servedAt becomes non-null (the subscriber marked it served).
  await waitFor(
    async () => {
      const list = await getJson(port, '/v1/annotations', signal);
      const found = list.annotations.find((a) => String(a.id) === annotationId);
      return found != null && found.servedAt !== null;
    },
    8000,
    'annotation servedAt',
    signal,
  );

  // 6. Call design_canvas_reply back over the same MCP connection, as Claude
  //    Code would once it has applied the annotation.
  const replyResult = await client.callTool({
    name: 'design_canvas_reply',
    arguments: {
      annotation_id: annotationId,
      status: 'applied',
      message: 'Made the primary button larger.',
    },
  });
  if (replyResult.isError) {
    throw new Error(`design_canvas_reply returned isError: ${JSON.stringify(replyResult)}`);
  }

  // 7. /v1/rounds reports the annotation as applied.
  await waitFor(
    async () => {
      const { rounds } = await getJson(port, '/v1/rounds?device=harness-ipad', signal);
      const round = rounds.find((r) => r.annotationId === annotationId);
      return round != null && round.status === 'applied';
    },
    8000,
    '/v1/rounds reporting applied',
    signal,
  );
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

async function waitForHealth(targetPort, signal) {
  await waitFor(
    async () => {
      try {
        const response = await fetch(`http://127.0.0.1:${targetPort}/v1/health`, { signal });
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

async function postJson(targetPort, path, body, signal) {
  const response = await fetch(`http://127.0.0.1:${targetPort}${path}`, {
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

async function getJson(targetPort, path, signal) {
  const response = await fetch(`http://127.0.0.1:${targetPort}${path}`, { signal });
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
// that is an acceptable trade for a test harness and far safer than a fixed
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
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    });
  });
  if (typeof address !== 'object' || address === null) {
    throw new Error('Could not allocate a free TCP port for channel harness');
  }
  return address.port;
}
