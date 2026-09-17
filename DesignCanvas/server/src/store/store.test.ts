import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { CAPTURE_TTL_MS } from '../shared.js';
import { DesignCanvasStore, UnknownCaptureError } from './store.js';
import { createStorePaths } from './paths.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function tempStore(): Promise<DesignCanvasStore> {
  const root = await mkdtemp(join(tmpdir(), 'dc-store-'));
  // createStorePaths(root) supplies all required StorePaths fields (root/captures/annotations).
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  return store;
}

test('capture round-trips viewport at schema version 3', async () => {
  const store = await tempStore();
  const meta = await store.createCapture({
    screenshot: Buffer.from('png'),
    viewport: { w: 1440, h: 900 },
  });
  assert.equal(meta.schemaVersion, 3);
  assert.deepEqual(meta.viewport, { w: 1440, h: 900 });
  const latest = await store.latestCapture();
  assert.deepEqual(latest?.meta.viewport, { w: 1440, h: 900 });
});

test('annotation upload happy path writes four files and schema 3 meta with device and zoomRect', async () => {
  const store = await tempStore();
  const capture = await store.createCapture({
    screenshot: Buffer.from('shot'),
    viewport: { w: 100, h: 200 },
  });
  const meta = await store.createAnnotation({
    composite: Buffer.from('composite'),
    sketch: Buffer.from('sketch'),
    sourceCaptureId: capture.id,
    viewport: { w: 100, h: 200 },
    zoomRect: { x: 0.1, y: 0.2, w: 0.5, h: 0.4 },
    device: { id: 'device-1', name: 'iPad' },
    note: { text: 'make it bigger' },
  });

  assert.equal(meta.schemaVersion, 3);
  assert.deepEqual(meta.device, { id: 'device-1', name: 'iPad' });
  assert.deepEqual(meta.zoomRect, { x: 0.1, y: 0.2, w: 0.5, h: 0.4 });
  assert.equal(meta.reply, null);
  assert.equal(meta.claimedAt, null);
  assert.equal(meta.servedAt, null);
  assert.equal(meta.note.text, 'make it bigger');

  const dir = join(store.paths.annotations, meta.id);
  assert.equal((await readFile(join(dir, 'composite.png'))).toString(), 'composite');
  assert.equal((await readFile(join(dir, 'sketch.png'))).toString(), 'sketch');
  assert.equal((await readFile(join(dir, 'screenshot.png'))).toString(), 'shot');
  await readFile(join(dir, 'meta.json'));
});

// I5: every Draw Mode entry posts a full-resolution capture whether the sketch is
// ever sent or not, and `createAnnotation` copies the screenshot it needs — so the
// capture directory was pure accumulation.

test('creating an annotation consumes its capture directory', async () => {
  const store = await tempStore();
  const capture = await store.createCapture({
    screenshot: Buffer.from('shot'),
    viewport: { w: 100, h: 200 },
  });
  const meta = await store.createAnnotation({
    composite: Buffer.from('composite'),
    sketch: Buffer.from('sketch'),
    sourceCaptureId: capture.id,
    viewport: { w: 100, h: 200 },
    zoomRect: null,
    device: { id: 'device-1', name: 'iPad' },
  });

  assert.deepEqual(await readdir(store.paths.captures), [], 'the consumed capture is gone');
  assert.equal(await store.getCapture(capture.id), null);
  // The annotation keeps its own copy of the clean frame.
  assert.equal(
    (await readFile(join(store.paths.annotations, meta.id, 'screenshot.png'))).toString(),
    'shot',
  );
});

test('an annotation records when its frame was captured, so deleting the capture loses nothing', async () => {
  const store = await tempStore();
  const capture = await store.createCapture({
    screenshot: Buffer.from('shot'),
    viewport: { w: 1, h: 1 },
    createdAt: '2026-02-01T00:00:00.000Z',
  });
  const meta = await store.createAnnotation({
    composite: Buffer.from('c'),
    sketch: Buffer.from('s'),
    sourceCaptureId: capture.id,
    viewport: { w: 1, h: 1 },
    zoomRect: null,
    device: { id: 'd', name: 'n' },
  });
  assert.equal(meta.capturedAt, '2026-02-01T00:00:00.000Z');
  assert.equal(meta.schemaVersion, 3, 'additive field, no schema bump');

  const read = await store.getAnnotation(meta.id);
  assert.equal(read?.meta.capturedAt, '2026-02-01T00:00:00.000Z');
});

test('pruneCaptures drops captures past the TTL and keeps the rest', async () => {
  const store = await tempStore();
  const now = Date.parse('2026-02-01T12:00:00.000Z');
  const stale = await store.createCapture({
    screenshot: Buffer.from('old'),
    viewport: { w: 1, h: 1 },
    createdAt: '2026-02-01T05:00:00.000Z',
  });
  const fresh = await store.createCapture({
    screenshot: Buffer.from('new'),
    viewport: { w: 1, h: 1 },
    createdAt: '2026-02-01T11:00:00.000Z',
  });

  const removed = await store.pruneCaptures(CAPTURE_TTL_MS, new Date(now));

  assert.equal(removed, 1);
  assert.equal(await store.getCapture(stale.id), null);
  assert.notEqual(await store.getCapture(fresh.id), null);
});

test('pruneCaptures leaves an unreadable capture directory alone', async () => {
  const store = await tempStore();
  await mkdir(join(store.paths.captures, 'no-meta-here'), { recursive: true });
  assert.equal(await store.pruneCaptures(CAPTURE_TTL_MS, new Date()), 0);
  assert.deepEqual(await readdir(store.paths.captures), ['no-meta-here']);
});

test('creating an annotation with an unknown sourceCaptureId fails and writes nothing', async () => {
  const store = await tempStore();
  await assert.rejects(
    store.createAnnotation({
      composite: Buffer.from('composite'),
      sketch: Buffer.from('sketch'),
      sourceCaptureId: 'does-not-exist',
      viewport: { w: 1, h: 1 },
      zoomRect: null,
      device: { id: 'd', name: 'n' },
    }),
    (error: unknown) => error instanceof UnknownCaptureError,
  );
  const entries = await readdir(store.paths.annotations);
  assert.deepEqual(entries, []);
});

test('a v2 annotation record reads with device, zoomRect, and reply defaults', async () => {
  const store = await tempStore();
  const id = 'legacy-v2-annotation';
  const dir = join(store.paths.annotations, id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'composite.png'), Buffer.from('png'));
  await writeFile(
    join(dir, 'meta.json'),
    JSON.stringify({
      id,
      schemaVersion: 2,
      createdAt: '2026-01-01T00:00:00.000Z',
      servedAt: null,
      claimedAt: null,
      sourceLabel: 'ignored on read',
      viewport: { w: 1, h: 1 },
      note: { text: 'legacy note', voiceFile: null },
      sourceCaptureId: 'legacy-capture-1',
    }),
  );

  const annotation = await store.getAnnotation(id);
  assert.ok(annotation);
  assert.deepEqual(annotation?.meta.device, { id: '', name: '' });
  assert.equal(annotation?.meta.zoomRect, null);
  assert.equal(annotation?.meta.reply, null);
  assert.equal(annotation?.meta.note.text, 'legacy note');
  assert.equal((annotation?.meta as { sourceLabel?: string }).sourceLabel, undefined);
});
