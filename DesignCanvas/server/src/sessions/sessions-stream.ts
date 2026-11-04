import type { IncomingMessage, ServerResponse } from 'node:http';
import type { SessionsSnapshot } from '../shared.js';
import { openSseStream } from '../http/event-stream.js';

type Listener = (snapshot: SessionsSnapshot) => void;

/** In-memory pub/sub for the session list; the Mac app is its one subscriber. */
export class SessionsEventBus {
  private readonly listeners = new Set<Listener>();

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(snapshot: SessionsSnapshot): void {
    for (const listener of this.listeners) {
      try {
        listener(snapshot);
      } catch {
        // A failing subscriber must not break delivery to others.
      }
    }
  }
}

/**
 * Holds an SSE connection open, writing `sessions.updated` with the whole snapshot on
 * every change. The current snapshot goes out first, so a subscriber never has to
 * pair the stream with a separate GET to learn where things stand.
 */
export function openSessionsStream(
  request: IncomingMessage,
  response: ServerResponse,
  bus: SessionsEventBus,
  current: () => SessionsSnapshot,
): void {
  openSseStream(request, response, (write) => {
    write('sessions.updated', JSON.stringify(current()));
    return bus.subscribe((snapshot) => write('sessions.updated', JSON.stringify(snapshot)));
  });
}
