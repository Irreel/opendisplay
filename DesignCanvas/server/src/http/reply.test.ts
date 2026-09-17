import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AnnotationMeta } from '../shared.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { startHttpServer } from './server.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function withServer(
  run: (base: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), 'dc-reply-http-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({ port: 0, version: '0.0.0', store, bus, logger: silentLogger });
  try {
    const { port } = server.address() as AddressInfo;
    await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

async function createAnnotation(base: string): Promise<string> {
  const captureResponse = await fetch(`${base}/v1/captures`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      screenshotBase64: Buffer.from('png').toString('base64'),
      viewport: { w: 100, h: 200 },
    }),
  });
  const { captureId } = (await captureResponse.json()) as { captureId: string };
  const annotationResponse = await fetch(`${base}/v1/annotations`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      compositeBase64: Buffer.from('composite').toString('base64'),
      sketchBase64: Buffer.from('sketch').toString('base64'),
      sourceCaptureId: captureId,
      viewport: { w: 100, h: 200 },
      zoomRect: null,
      device: { id: 'device-1', name: 'iPad' },
    }),
  });
  const { annotationId } = (await annotationResponse.json()) as { annotationId: string };
  return annotationId;
}

test('reply happy path stores the full 5000-byte message and can arrive before served', async () => {
  await withServer(async (base) => {
    const id = await createAnnotation(base);
    const bigMessage = 'y'.repeat(5000);
    const response = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'applied', message: bigMessage, prUrl: 'https://example.com/pr/9' }),
    });
    assert.equal(response.status, 200);
    const { meta } = (await response.json()) as { meta: AnnotationMeta };
    assert.equal(meta.servedAt, null);
    assert.equal(meta.reply?.status, 'applied');
    assert.equal(meta.reply?.message?.length, 5000);
    assert.equal(meta.reply?.prUrl, 'https://example.com/pr/9');
  });
});

test('a second reply is refused with 409 already_replied', async () => {
  await withServer(async (base) => {
    const id = await createAnnotation(base);
    const first = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'applied' }),
    });
    assert.equal(first.status, 200);
    const second = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'failed' }),
    });
    assert.equal(second.status, 409);
    const body = (await second.json()) as { error: string };
    assert.equal(body.error, 'already_replied');
  });
});

test('an unrecognized status is rejected with 400 invalid_request', async () => {
  await withServer(async (base) => {
    const id = await createAnnotation(base);
    const response = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'bogus' }),
    });
    assert.equal(response.status, 400);
    const body = (await response.json()) as { error: string };
    assert.equal(body.error, 'invalid_request');
  });
});

test('a non-string message is rejected with 400 invalid_request', async () => {
  await withServer(async (base) => {
    const id = await createAnnotation(base);
    const response = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'applied', message: 42 }),
    });
    assert.equal(response.status, 400);
  });
});

test('replying to an unknown annotation id returns 404', async () => {
  await withServer(async (base) => {
    const response = await fetch(`${base}/v1/annotations/does-not-exist/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'applied' }),
    });
    assert.equal(response.status, 404);
    const body = (await response.json()) as { error: string };
    assert.equal(body.error, 'annotation_not_found');
  });
});

test('a reply after served still succeeds', async () => {
  await withServer(async (base) => {
    const id = await createAnnotation(base);
    const served = await fetch(`${base}/v1/annotations/${id}/served`, { method: 'POST' });
    assert.equal(served.status, 200);
    const response = await fetch(`${base}/v1/annotations/${id}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'needs_input', message: 'need more detail' }),
    });
    assert.equal(response.status, 200);
    const { meta } = (await response.json()) as { meta: AnnotationMeta };
    assert.notEqual(meta.servedAt, null);
    assert.equal(meta.reply?.status, 'needs_input');
  });
});
