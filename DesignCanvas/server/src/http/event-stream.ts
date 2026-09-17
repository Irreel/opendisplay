import type { IncomingMessage, ServerResponse } from 'node:http';

type Listener = (annotationId: string) => void;

export class AnnotationEventBus {
  // Map insertion order tracks attach order, so the first entry is always the oldest.
  private readonly listeners = new Map<Listener, string>();

  get subscriberCount(): number {
    return this.listeners.size;
  }

  /** ISO time the oldest current subscriber attached; null when there are none. */
  get oldestAttachedAt(): string | null {
    const oldest = this.listeners.values().next();
    return oldest.done ? null : oldest.value;
  }

  subscribe(listener: Listener): () => void {
    this.listeners.set(listener, new Date().toISOString());
    return () => this.listeners.delete(listener);
  }

  emitPending(annotationId: string): void {
    for (const listener of this.listeners.keys()) {
      try {
        listener(annotationId);
      } catch {
        // A failing subscriber (e.g. a dead SSE socket) must not break delivery to others.
      }
    }
  }
}

/** Only 127.0.0.1 / ::1 may reach the internal channel endpoints. */
export function isLoopback(request: IncomingMessage): boolean {
  const addr = request.socket.remoteAddress ?? '';
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';
}

/**
 * An SSE comment line: ignored by every consumer's parser (the Mac's
 * `SSEParser`, the channel subscriber's frame reader), and the only thing that
 * keeps a silent stream alive.
 */
export const SSE_KEEPALIVE = ': ka\n\n';

/**
 * How often that comment goes out. Both consumers give up on an idle stream:
 * the Mac's `URLRequest` has a 60 s *idle* timeout, and the channel's `fetch`
 * hits undici's 300 s body timeout — which dropped `channelCount` to 0 for the
 * length of a reconnect and made the Mac app read a routine reconnect as "the
 * user quit Claude Code". 15 s is comfortably inside both.
 */
export const SSE_KEEPALIVE_MS = 15_000;

/**
 * Starts the keep-alive beat for one stream. `unref()`'d, so it never holds
 * the daemon's event loop open; the caller clears it when the stream closes.
 */
export function startSseKeepAlive(
  response: ServerResponse,
  intervalMs = SSE_KEEPALIVE_MS,
): NodeJS.Timeout {
  const timer = setInterval(() => {
    if (!response.writableEnded) {
      response.write(SSE_KEEPALIVE);
    }
  }, intervalMs);
  timer.unref();
  return timer;
}

/**
 * Shared SSE plumbing: writes the standard preamble, beats a keep-alive
 * comment every `keepAliveMs`, then lets `subscribe` attach to whatever bus
 * it's given via the `write(eventName, data)` callback. Unsubscribes and stops
 * the beat on close/error either side. Both the annotation stream and the
 * rounds stream (rounds-stream.ts) are built on this.
 */
export function openSseStream(
  request: IncomingMessage,
  response: ServerResponse,
  subscribe: (write: (eventName: string, data: string) => void) => () => void,
  keepAliveMs = SSE_KEEPALIVE_MS,
): void {
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });
  response.write('retry: 1000\n\n');
  const write = (eventName: string, data: string) => {
    if (!response.writableEnded) {
      response.write(`event: ${eventName}\ndata: ${data}\n\n`);
    }
  };
  const unsubscribe = subscribe(write);
  const keepAlive = startSseKeepAlive(response, keepAliveMs);
  const close = () => {
    clearInterval(keepAlive);
    unsubscribe();
  };
  request.on('close', close);
  request.on('error', close);
  response.on('error', close);
}

/** Holds an SSE connection open, writing `annotation.pending` events until the client disconnects. */
export function openAnnotationStream(
  request: IncomingMessage,
  response: ServerResponse,
  bus: AnnotationEventBus,
): void {
  openSseStream(request, response, (write) =>
    bus.subscribe((id) => write('annotation.pending', id)),
  );
}
