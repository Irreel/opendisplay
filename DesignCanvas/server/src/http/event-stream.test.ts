import type { IncomingMessage } from 'node:http';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AnnotationEventBus, isLoopback } from './event-stream.js';

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

test('isLoopback accepts loopback addresses and rejects others', () => {
  const make = (addr: string | undefined) =>
    ({ socket: { remoteAddress: addr } }) as unknown as IncomingMessage;
  assert.equal(isLoopback(make('127.0.0.1')), true);
  assert.equal(isLoopback(make('::1')), true);
  assert.equal(isLoopback(make('::ffff:127.0.0.1')), true);
  assert.equal(isLoopback(make('192.168.1.50')), false);
  assert.equal(isLoopback(make(undefined)), false);
});
