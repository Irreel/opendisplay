import type { IncomingMessage, ServerResponse } from 'node:http';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  AnnotationEventBus,
  isLoopback,
  openSseStream,
  SSE_KEEPALIVE,
  startSseKeepAlive,
} from './event-stream.js';

test('bus delivers events to subscribers and counts them', () => {
  const bus = new AnnotationEventBus();
  const received: string[] = [];
  const unsub = bus.subscribe((id) => received.push(id));
  assert.equal(bus.subscriberCount, 1);
  bus.emitPending('annotation-123');
  assert.deepEqual(received, ['annotation-123']);
  unsub();
  assert.equal(bus.subscriberCount, 0);
});

test('bus tracks the oldest current subscriber attach time', async () => {
  const bus = new AnnotationEventBus();
  assert.equal(bus.oldestAttachedAt, null);

  const unsubFirst = bus.subscribe(() => {});
  const firstAttachedAt = bus.oldestAttachedAt;
  assert.equal(typeof firstAttachedAt, 'string');

  await new Promise((resolve) => setTimeout(resolve, 5));
  const unsubSecond = bus.subscribe(() => {});
  // The oldest subscriber is still the first one.
  assert.equal(bus.oldestAttachedAt, firstAttachedAt);

  unsubFirst();
  // The oldest surviving subscriber is now the second one, attached later.
  assert.notEqual(bus.oldestAttachedAt, firstAttachedAt);
  assert.equal(typeof bus.oldestAttachedAt, 'string');

  unsubSecond();
  assert.equal(bus.oldestAttachedAt, null);
});

/** A request/response pair that records what an SSE stream writes to it. */
function fakeSsePeer() {
  const writes: string[] = [];
  const handlers = new Map<string, (() => void)[]>();
  const on = (target: unknown) => (event: string, handler: () => void) => {
    handlers.set(event, [...(handlers.get(event) ?? []), handler]);
    return target;
  };
  const requestSpy: Record<string, unknown> = {};
  requestSpy['on'] = on(requestSpy);
  const responseSpy: Record<string, unknown> = {
    writableEnded: false,
    writeHead: () => responseSpy,
    write: (chunk: string) => {
      writes.push(chunk);
      return true;
    },
    end: () => {
      responseSpy['writableEnded'] = true;
    },
  };
  responseSpy['on'] = on(responseSpy);
  return {
    request: requestSpy as unknown as IncomingMessage,
    response: responseSpy as unknown as ServerResponse,
    writes,
    keepAlives: () => writes.filter((chunk) => chunk === SSE_KEEPALIVE),
    fire: (event: string) => (handlers.get(event) ?? []).forEach((handler) => handler()),
    endResponse: () => {
      responseSpy['writableEnded'] = true;
    },
  };
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test('an SSE stream writes a keep-alive comment on its interval', async () => {
  const peer = fakeSsePeer();
  openSseStream(peer.request, peer.response, () => () => {}, 10);
  assert.equal(peer.keepAlives().length, 0, 'nothing is written up front but the retry hint');

  await delay(45);
  const beats = peer.keepAlives().length;
  assert.ok(beats >= 2, `expected at least 2 keep-alives, got ${beats}`);
  peer.fire('close');
});

test('the keep-alive timer is unrefd, so it never holds the daemon open', () => {
  const peer = fakeSsePeer();
  const timer = startSseKeepAlive(peer.response, 10);
  assert.equal(timer.hasRef(), false);
  clearInterval(timer);
});

test('closing an SSE stream stops its keep-alive', async () => {
  const peer = fakeSsePeer();
  openSseStream(peer.request, peer.response, () => () => {}, 10);
  await delay(45);
  const atClose = peer.keepAlives().length;
  assert.ok(atClose >= 2);

  peer.fire('close');
  await delay(45);
  assert.equal(peer.keepAlives().length, atClose, 'no beat after the client went away');
});

test('a keep-alive is never written to an already-ended response', async () => {
  const peer = fakeSsePeer();
  openSseStream(peer.request, peer.response, () => () => {}, 10);
  peer.endResponse();
  await delay(45);
  assert.equal(peer.keepAlives().length, 0);
  peer.fire('close');
});

test('closing an SSE stream unsubscribes it from its bus', async () => {
  const bus = new AnnotationEventBus();
  const peer = fakeSsePeer();
  openSseStream(peer.request, peer.response, (write) => bus.subscribe((id) => write('annotation.pending', id)), 10);
  assert.equal(bus.subscriberCount, 1);
  peer.fire('close');
  assert.equal(bus.subscriberCount, 0);
});

test('isLoopback accepts loopback addresses and rejects others', () => {
  const make = (addr: string | undefined) =>
    ({ socket: { remoteAddress: addr } }) as unknown as IncomingMessage;
  assert.equal(isLoopback(make('127.0.0.1')), true);
  assert.equal(isLoopback(make('::1')), true);
  assert.equal(isLoopback(make('::ffff:127.0.0.1')), true);
  assert.equal(isLoopback(make('192.168.1.50')), false);
  assert.equal(isLoopback(make(undefined)), false);
});
