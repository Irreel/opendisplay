import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { DesignCanvasStore } from './store.js';
import { createStorePaths } from './paths.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function storeWithAnnotation(captureCreatedAt?: string) {
  const root = await mkdtemp(join(tmpdir(), 'dc-claim-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const capture = await store.createCapture({
    screenshot: Buffer.from('p'),
    viewport: { w: 1, h: 1 },
    ...(captureCreatedAt ? { createdAt: captureCreatedAt } : {}),
  });
  const ann = await store.createAnnotation({
    composite: Buffer.from('c'),
    sketch: Buffer.from('s'),
    sourceCaptureId: capture.id,
    viewport: { w: 1, h: 1 },
    zoomRect: null,
    device: { id: 'device-1', name: 'iPad' },
  });
  return { store, id: ann.id, captureId: capture.id };
}

test('first claim wins, concurrent second claim loses', async () => {
  const { store, id } = await storeWithAnnotation();
  const [a, b] = await Promise.all([store.claimAnnotation(id), store.claimAnnotation(id)]);
  const winners = [a, b].filter((x) => x !== null);
  assert.equal(winners.length, 1);
  assert.equal(typeof winners[0]?.meta.claimedAt, 'string');
  assert.notEqual(winners[0]?.meta.claimedAt, null);
});

test('claim after served returns null', async () => {
  const { store, id } = await storeWithAnnotation();
  assert.notEqual(await store.claimAnnotation(id), null);
  await store.markAnnotationServed(id);
  assert.equal(await store.claimAnnotation(id), null);
});

test('live lease blocks immediate re-claim under default lease', async () => {
  const { store, id } = await storeWithAnnotation();
  assert.notEqual(await store.claimAnnotation(id), null);
  // Default lease is live, so a second immediate claim must lose (no reconcile path).
  assert.equal(await store.claimAnnotation(id), null);
});

test('serving annotation is excluded from pending until lease expires', async () => {
  const { store, id } = await storeWithAnnotation();
  await store.claimAnnotation(id);
  assert.equal((await store.pendingAnnotations()).length, 0);
  // negative lease => everything is instantly stale (test-only affordance)
  const reset = await store.reconcileStaleClaims(-1);
  assert.equal(reset, 1);
  assert.equal((await store.pendingAnnotations()).length, 1);
});

/// The capture directory is consumed the moment the annotation is created (I5), so
/// `capturedAt` has to come from what the annotation recorded — not from a capture
/// that is already gone by the time the channel claims it.
test('claim carries capturedAt recorded when the annotation was created', async () => {
  const captureCreatedAt = '2026-02-01T00:00:00.000Z';
  const { store, id, captureId } = await storeWithAnnotation(captureCreatedAt);
  assert.equal(await store.getCapture(captureId), null, 'consumed at creation');
  const claimed = await store.claimAnnotation(id);
  assert.equal(claimed?.capturedAt, captureCreatedAt);
});

test('claim falls back to the annotation createdAt for a record that never recorded one', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-claim-legacy-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const id = 'annotation-without-capturedat';
  const dir = join(store.paths.annotations, id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'composite.png'), Buffer.from('c'));
  await writeFile(
    join(dir, 'meta.json'),
    JSON.stringify({
      id,
      schemaVersion: 3,
      createdAt: '2026-03-01T00:00:00.000Z',
      claimedAt: null,
      servedAt: null,
      viewport: { w: 1, h: 1 },
      zoomRect: null,
      note: { text: null },
      sourceCaptureId: 'a-capture-long-since-swept',
      device: { id: 'device-1', name: 'iPad' },
      reply: null,
    }),
  );

  const claimed = await store.claimAnnotation(id);
  assert.equal(claimed?.capturedAt, '2026-03-01T00:00:00.000Z');
});
