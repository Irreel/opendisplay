import type { IncomingMessage, ServerResponse } from 'node:http';
import type { RoundEvent } from '../shared.js';
import { openSseStream } from './event-stream.js';

type Listener = (event: RoundEvent) => void;

/**
 * In-memory pub/sub for round.updated events: emitted when an annotation is
 * created (queued), marked served (sent), and replied. Unlike
 * AnnotationEventBus, subscribers here are never counted toward the daemon's
 * channelCount -- this stream is for the engine, not the channel process.
 */
export class RoundsEventBus {
  private readonly listeners = new Set<Listener>();

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(event: RoundEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch {
        // A failing subscriber (e.g. a dead SSE socket) must not break delivery to others.
      }
    }
  }
}

/** Holds an SSE connection open, writing `round.updated` events until the client disconnects. */
export function openRoundsStream(
  request: IncomingMessage,
  response: ServerResponse,
  bus: RoundsEventBus,
): void {
  openSseStream(request, response, (write) =>
    bus.subscribe((event) => write('round.updated', JSON.stringify(event))),
  );
}
