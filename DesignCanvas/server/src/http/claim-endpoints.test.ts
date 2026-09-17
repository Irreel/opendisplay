import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
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

test('loopback claim/served endpoints drive the annotation lifecycle', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-claim-http-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({
    port: 0,
    version: '0.0.0',
    store,
    bus,
    logger: silentLogger,
  });

  try {
    const { port } = server.address() as AddressInfo;
    const base = `http://127.0.0.1:${port}`;

    const captureResponse = await fetch(`${base}/v1/captures`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        screenshotBase64: Buffer.from('png').toString('base64'),
        viewport: { w: 100, h: 200 },
      }),
    });
    assert.equal(captureResponse.status, 201);
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
    assert.equal(annotationResponse.status, 201);
    const { annotationId } = (await annotationResponse.json()) as { annotationId: string };

    const claim = await fetch(`${base}/v1/annotations/${annotationId}/claim`, { method: 'POST' });
    assert.equal(claim.status, 200);
    const claimBody = (await claim.json()) as {
      compositePath: string;
      meta: { id: string };
      capturedAt: string;
    };
    assert.equal(typeof claimBody.compositePath, 'string');
    assert.equal(claimBody.meta.id, annotationId);
    assert.equal(typeof claimBody.capturedAt, 'string');

    const secondClaim = await fetch(`${base}/v1/annotations/${annotationId}/claim`, {
      method: 'POST',
    });
    assert.equal(secondClaim.status, 409);

    const served = await fetch(`${base}/v1/annotations/${annotationId}/served`, { method: 'POST' });
    assert.equal(served.status, 200);

    const list = await fetch(`${base}/v1/annotations`);
    assert.equal(list.status, 200);
    const { annotations } = (await list.json()) as {
      annotations: { id: string; servedAt: string | null }[];
    };
    const found = annotations.find((annotation) => annotation.id === annotationId);
    assert.ok(found);
    assert.notEqual(found.servedAt, null);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('marking an unknown annotation as served returns 404', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-served-404-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({
    port: 0,
    version: '0.0.0',
    store,
    bus,
    logger: silentLogger,
  });

  try {
    const { port } = server.address() as AddressInfo;
    const served = await fetch(`http://127.0.0.1:${port}/v1/annotations/does-not-exist/served`, {
      method: 'POST',
    });
    assert.equal(served.status, 404);
    const body = (await served.json()) as { error: string };
    assert.equal(body.error, 'annotation_not_found');
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
