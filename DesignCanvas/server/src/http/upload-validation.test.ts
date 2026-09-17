import assert from 'node:assert/strict';
import { mkdtemp, readdir } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { startHttpServer } from './server.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function withServer(
  run: (store: DesignCanvasStore, base: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), 'dc-upload-validation-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({ port: 0, version: '0.0.0', store, bus, logger: silentLogger });
  try {
    const { port } = server.address() as AddressInfo;
    await run(store, `http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

async function assertInvalidRequest(response: Response): Promise<void> {
  assert.equal(response.status, 400);
  const body = (await response.json()) as { error: string };
  assert.equal(body.error, 'invalid_request');
}

test('malformed JSON on POST /v1/captures is 400 invalid_request, not 500', async () => {
  await withServer(async (_store, base) => {
    const response = await fetch(`${base}/v1/captures`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{not json',
    });
    await assertInvalidRequest(response);
  });
});

test('malformed JSON on POST /v1/annotations is 400 invalid_request, not 500', async () => {
  await withServer(async (_store, base) => {
    const response = await fetch(`${base}/v1/annotations`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{not json',
    });
    await assertInvalidRequest(response);
  });
});

test('a malformed meta part inside a multipart annotation upload is 400 invalid_request, not 500', async () => {
  await withServer(async (_store, base) => {
    const form = new FormData();
    form.set('meta', '{not json');
    form.set('composite', new Blob([Buffer.from('composite')]));
    form.set('sketch', new Blob([Buffer.from('sketch')]));
    const response = await fetch(`${base}/v1/annotations`, { method: 'POST', body: form });
    await assertInvalidRequest(response);
  });
});

test('a multipart content-type with no boundary is 400 invalid_request, not 500', async () => {
  await withServer(async (_store, base) => {
    const response = await fetch(`${base}/v1/annotations`, {
      method: 'POST',
      headers: { 'content-type': 'multipart/form-data' },
      body: 'irrelevant',
    });
    await assertInvalidRequest(response);
  });
});

test('a JSON annotation body missing compositeBase64 is 400 invalid_request, not 500', async () => {
  await withServer(async (store, base) => {
    const capture = await store.createCapture({ screenshot: Buffer.from('p'), viewport: { w: 1, h: 1 } });
    const response = await fetch(`${base}/v1/annotations`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        sketchBase64: Buffer.from('s').toString('base64'),
        sourceCaptureId: capture.id,
        viewport: { w: 1, h: 1 },
        zoomRect: null,
        device: { id: 'device-1', name: 'iPad' },
      }),
    });
    await assertInvalidRequest(response);
  });
});

test('posting an annotation with an unknown sourceCaptureId is 404 capture_not_found and creates nothing', async () => {
  await withServer(async (store, base) => {
    const response = await fetch(`${base}/v1/annotations`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        compositeBase64: Buffer.from('c').toString('base64'),
        sketchBase64: Buffer.from('s').toString('base64'),
        sourceCaptureId: 'does-not-exist',
        viewport: { w: 1, h: 1 },
        zoomRect: null,
        device: { id: 'device-1', name: 'iPad' },
      }),
    });
    assert.equal(response.status, 404);
    const body = (await response.json()) as { error: string };
    assert.equal(body.error, 'capture_not_found');
    const entries = await readdir(store.paths.annotations);
    assert.deepEqual(entries, []);
  });
});
