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
 * Shared SSE plumbing: writes the standard preamble, then lets `subscribe`
 * attach to whatever bus it's given via the `write(eventName, data)` callback.
 * Unsubscribes on close/error either side. Both the annotation stream and the
 * rounds stream (rounds-stream.ts) are built on this.
 */
export function openSseStream(
  request: IncomingMessage,
  response: ServerResponse,
  subscribe: (write: (eventName: string, data: string) => void) => () => void,
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
  request.on('close', unsubscribe);
  request.on('error', unsubscribe);
  response.on('error', unsubscribe);
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
