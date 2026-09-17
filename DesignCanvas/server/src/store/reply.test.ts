import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { DesignCanvasStore } from './store.js';
import { createStorePaths } from './paths.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function storeWithAnnotation() {
  const root = await mkdtemp(join(tmpdir(), 'dc-reply-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const capture = await store.createCapture({ screenshot: Buffer.from('p'), viewport: { w: 1, h: 1 } });
  const ann = await store.createAnnotation({
    composite: Buffer.from('c'),
    sketch: Buffer.from('s'),
    sourceCaptureId: capture.id,
    viewport: { w: 1, h: 1 },
    zoomRect: null,
    device: { id: 'device-1', name: 'iPad' },
  });
  return { store, id: ann.id };
}

test('setReply stores the full message and sets at', async () => {
  const { store, id } = await storeWithAnnotation();
  const bigMessage = 'x'.repeat(5000);
  const updated = await store.setReply(id, { status: 'applied', message: bigMessage, prUrl: null });
  assert.ok(updated);
  assert.equal(updated?.reply?.status, 'applied');
  assert.equal(updated?.reply?.message, bigMessage);
  assert.equal(updated?.reply?.message?.length, 5000);
  assert.equal(updated?.reply?.prUrl, null);
  assert.equal(typeof updated?.reply?.at, 'string');
});

test('a second reply is refused (returns null)', async () => {
  const { store, id } = await storeWithAnnotation();
  const first = await store.setReply(id, { status: 'applied', message: 'ok', prUrl: null });
  assert.ok(first);
  const second = await store.setReply(id, { status: 'failed', message: 'again', prUrl: null });
  assert.equal(second, null);
  // The first reply is preserved, not overwritten.
  const annotation = await store.getAnnotation(id);
  assert.equal(annotation?.meta.reply?.status, 'applied');
  assert.equal(annotation?.meta.reply?.message, 'ok');
});

test('a reply may be recorded before the annotation is served', async () => {
  const { store, id } = await storeWithAnnotation();
  const before = await store.getAnnotation(id);
  assert.equal(before?.meta.servedAt, null);
  const updated = await store.setReply(id, { status: 'needs_input', message: null, prUrl: null });
  assert.ok(updated);
  assert.equal(updated?.servedAt, null);
  assert.equal(updated?.reply?.status, 'needs_input');
});

test('a reply may also be recorded after the annotation is served', async () => {
  const { store, id } = await storeWithAnnotation();
  await store.markAnnotationServed(id);
  const updated = await store.setReply(id, {
    status: 'applied',
    message: 'done',
    prUrl: 'https://example.com/pr/1',
  });
  assert.ok(updated);
  assert.notEqual(updated?.servedAt, null);
  assert.equal(updated?.reply?.prUrl, 'https://example.com/pr/1');
});
