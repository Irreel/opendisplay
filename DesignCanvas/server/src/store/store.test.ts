import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { DesignCanvasStore } from './store.js';
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

test('capture round-trips sourceLabel', async () => {
  const store = await tempStore();
  const meta = await store.createCapture({
    screenshot: Buffer.from('png'),
    sourceLabel: 'localhost:3000 — Chrome',
    viewport: { w: 1440, h: 900 },
  });
  assert.equal(meta.sourceLabel, 'localhost:3000 — Chrome');
  assert.equal(meta.schemaVersion, 2);
  const latest = await store.latestCapture();
  assert.equal(latest?.meta.sourceLabel, 'localhost:3000 — Chrome');
});

test('reads a legacy v1 capture by mapping pageUrl to sourceLabel', async () => {
  const store = await tempStore();
  const id = 'legacy-1';
  const dir = join(store.paths.captures, id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'screenshot.png'), Buffer.from('png'));
  await writeFile(
    join(dir, 'meta.json'),
    JSON.stringify({ id, schemaVersion: 1, createdAt: '2026-01-01T00:00:00.000Z', pageUrl: 'http://old', viewport: { w: 1, h: 1 } }),
  );
  const capture = await store.getCapture(id);
  assert.equal(capture?.meta.sourceLabel, 'http://old');
});

test('reads a legacy v1 annotation by mapping pageUrl to sourceLabel', async () => {
  const store = await tempStore();
  const id = 'legacy-annotation-1';
  const dir = join(store.paths.annotations, id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'composite.png'), Buffer.from('png'));
  await writeFile(
    join(dir, 'meta.json'),
    JSON.stringify({
      id,
      schemaVersion: 1,
      createdAt: '2026-01-01T00:00:00.000Z',
      servedAt: null,
      pageUrl: 'http://old-annotation',
      viewport: { w: 1, h: 1 },
      note: { text: 'legacy note', voiceFile: null },
      sourceCaptureId: 'legacy-capture-1',
    }),
  );
  const annotation = await store.getAnnotation(id);
  assert.equal(annotation?.meta.sourceLabel, 'http://old-annotation');
});
