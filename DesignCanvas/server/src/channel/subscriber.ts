// The --channel subscriber: a thin loopback client of the daemon.
// It subscribes to the SSE stream, claims each pending annotation via the daemon,
// emits the channel notification, then marks it served. It replays backlog on
// (re)connect and reconnects with backoff on drop. See tech-doc and Task 9.

import { HTTP_PATHS, SERVER_PORT, type AnnotationMeta } from '../shared.js';
import type { Logger } from '../log.js';
import type { ChannelNotifier } from './index.js';

export interface SubscriberOptions {
  baseUrl?: string; // default http://127.0.0.1:<SERVER_PORT env || SERVER_PORT>
  channel: ChannelNotifier;
  logger: Logger;
  signal?: AbortSignal;
}

const BACKLOG_THROTTLE_MS = 1000;
const MIN_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 5000;

export async function runChannelSubscriber(opts: SubscriberOptions): Promise<void> {
  // Honor SERVER_PORT (mirroring the daemon) so a non-default daemon port is
  // reachable without an explicit baseUrl. Explicit baseUrl always wins.
  const port = process.env['SERVER_PORT'] ?? SERVER_PORT;
  const base = opts.baseUrl ?? `http://127.0.0.1:${port}`;
  const { channel, logger, signal } = opts;

  let backoff = MIN_BACKOFF_MS;
  while (!signal?.aborted) {
    try {
      await replayBacklog(base, channel, logger, signal);
      // readStream resets backoff once the connection is genuinely established
      // (response.ok confirmed), so a long-lived healthy connection that finally
      // errors reconnects from the minimum rather than a stale elevated backoff.
      await readStream(base, channel, logger, () => {
        backoff = MIN_BACKOFF_MS;
      }, signal);
      // Stream ended cleanly (server closed) — reconnect after a short pause.
      backoff = MIN_BACKOFF_MS;
    } catch (error) {
      if (signal?.aborted || isAbortError(error)) break;
      await logger.event('channel.subscriber.error', { message: errorMessage(error) });
    }
    if (signal?.aborted) break;
    await delay(backoff, signal);
    backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
  }
}

/** Claim → notify → served for one annotation id. Swallows per-id failures. */
async function handleId(
  base: string,
  id: string,
  channel: ChannelNotifier,
  logger: Logger,
  signal?: AbortSignal,
): Promise<void> {
  try {
    const claim = await fetch(`${base}/v1/annotations/${id}/claim`, {
      method: 'POST',
      ...(signal ? { signal } : {}),
    });
    if (claim.status !== 200) {
      // 409: someone else won or it is already served. Anything else: skip.
      return;
    }
    const { meta, compositePath, capturedAt } = (await claim.json()) as {
      meta: AnnotationMeta;
      compositePath: string;
      capturedAt: string;
    };
    await channel.notifyAnnotation({ meta, compositePath, capturedAt });
    const served = await fetch(`${base}/v1/annotations/${id}/served`, {
      method: 'POST',
      ...(signal ? { signal } : {}),
    });
    if (!served.ok) {
      // A stuck-served otherwise surfaces only as silent ~30s-cadence duplicate
      // notifications, so make the failure visible.
      await logger.event('channel.served.failed', { annotationId: id, status: served.status });
    }
  } catch (error) {
    if (isAbortError(error)) throw error;
    // An abort during notifyAnnotation (an MCP write, not a fetch) won't surface
    // as an AbortError, so don't log handle_error on shutdown — exit quietly.
    if (signal?.aborted) return;
    await logger.event('channel.subscriber.handle_error', { annotationId: id, message: errorMessage(error) });
  }
}

/** Fetch unserved annotations and run each through handleId, throttled. */
async function replayBacklog(
  base: string,
  channel: ChannelNotifier,
  logger: Logger,
  signal?: AbortSignal,
): Promise<void> {
  const response = await fetch(`${base}${HTTP_PATHS.annotations}`, {
    ...(signal ? { signal } : {}),
  });
  if (!response.ok) return;
  const { annotations } = (await response.json()) as { annotations: AnnotationMeta[] };
  const pending = annotations
    .filter((meta) => meta.servedAt === null)
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  for (let i = 0; i < pending.length; i += 1) {
    if (signal?.aborted) return;
    const meta = pending[i];
    if (!meta) continue;
    await handleId(base, meta.id, channel, logger, signal);
    if (i < pending.length - 1) {
      await delay(BACKLOG_THROTTLE_MS, signal);
    }
  }
}

/** Open the SSE stream and dispatch each annotation.pending id to handleId. */
async function readStream(
  base: string,
  channel: ChannelNotifier,
  logger: Logger,
  onConnected: () => void,
  signal?: AbortSignal,
): Promise<void> {
  const response = await fetch(`${base}${HTTP_PATHS.annotationStream}`, {
    ...(signal ? { signal } : {}),
  });
  if (!response.ok || !response.body) {
    throw new Error(`stream connect failed: ${response.status}`);
  }
  // The TCP+HTTP connect genuinely succeeded — reset backoff now so a healthy
  // long-lived connection that later errors reconnects from the minimum. We do
  // NOT reset before response.ok, so a flaky accept-then-error daemon still backs off.
  onConnected();
  const decoder = new TextDecoder();
  let buffer = '';
  // response.body is an async iterable of Uint8Array in Node 20.
  for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
    buffer += decoder.decode(chunk, { stream: true });
    // SSE frames are separated by a blank line. We assume LF framing ('\n\n')
    // because the only producer is our own loopback daemon — no '\r\n' or bare-'\r'.
    let boundary = buffer.indexOf('\n\n');
    while (boundary !== -1) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const id = parseDataId(frame);
      if (id) await handleId(base, id, channel, logger, signal);
      boundary = buffer.indexOf('\n\n');
    }
    if (signal?.aborted) return;
  }
}

/** Extract the id from the `data:` line of an SSE frame, if it is a pending event. */
function parseDataId(frame: string): string | null {
  let data: string | null = null;
  for (const line of frame.split('\n')) {
    if (line.startsWith('data:')) {
      data = line.slice('data:'.length).trim();
    }
  }
  return data && data.length > 0 ? data : null;
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise<void>((resolve) => {
    if (signal?.aborted) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      resolve();
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
