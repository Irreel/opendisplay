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
  const root = await mkdtemp(join(tmpdir(), 'dc-claim-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const capture = await store.createCapture({ screenshot: Buffer.from('p'), sourceLabel: 'w', viewport: { w: 1, h: 1 } });
  const ann = await store.createAnnotation({ composite: Buffer.from('c'), sourceCaptureId: capture.id, sourceLabel: 'w', viewport: { w: 1, h: 1 } });
  return { store, id: ann.id };
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
