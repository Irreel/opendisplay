import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { HealthResponse, RoundEvent } from '../shared.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { startHttpServer } from './server.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('waitFor timed out');
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

/** Collects round.updated SSE events from a response body into `events`. */
function collectRoundEvents(body: ReadableStream<Uint8Array>, events: RoundEvent[]): void {
  void (async () => {
    const decoder = new TextDecoder();
    let buffer = '';
    try {
      for await (const chunk of body as unknown as AsyncIterable<Uint8Array>) {
        buffer += decoder.decode(chunk, { stream: true });
        let boundary = buffer.indexOf('\n\n');
        while (boundary !== -1) {
          const frame = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          const dataLine = frame.split('\n').find((line) => line.startsWith('data:'));
          if (dataLine) {
            events.push(JSON.parse(dataLine.slice('data:'.length).trim()) as RoundEvent);
          }
          boundary = buffer.indexOf('\n\n');
        }
      }
    } catch {
      // Connection aborted by the test teardown; nothing to collect further.
    }
  })();
}

test('the rounds stream delivers queued, sent, then applied in order with the right deviceId', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-rounds-stream-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({ port: 0, version: '0.0.0', store, bus, logger: silentLogger });
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  const controller = new AbortController();
  const streamResponse = await fetch(`${base}/v1/rounds/stream`, { signal: controller.signal });
  assert.ok(streamResponse.body);
  const events: RoundEvent[] = [];
  collectRoundEvents(streamResponse.body, events);

  try {
    const capture = await store.createCapture({ screenshot: Buffer.from('p'), viewport: { w: 1, h: 1 } });
    const annotationResponse = await fetch(`${base}/v1/annotations`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        compositeBase64: Buffer.from('c').toString('base64'),
        sketchBase64: Buffer.from('s').toString('base64'),
        sourceCaptureId: capture.id,
        viewport: { w: 1, h: 1 },
        zoomRect: null,
        device: { id: 'device-1', name: 'iPad' },
      }),
    });
    const { annotationId } = (await annotationResponse.json()) as { annotationId: string };

    await waitFor(() => events.length >= 1, 2000);
    await fetch(`${base}/v1/annotations/${annotationId}/served`, { method: 'POST' });
    await waitFor(() => events.length >= 2, 2000);
    await fetch(`${base}/v1/annotations/${annotationId}/reply`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ status: 'applied' }),
    });
    await waitFor(() => events.length >= 3, 2000);

    assert.equal(events.length, 3);
    assert.equal(events[0]?.status, 'queued');
    assert.equal(events[1]?.status, 'sent');
    assert.equal(events[2]?.status, 'applied');
    for (const event of events) {
      assert.equal(event.deviceId, 'device-1');
      assert.equal(event.annotationId, annotationId);
    }
  } finally {
    controller.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('opening the rounds stream leaves channelCount at 0', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-rounds-stream-count-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const bus = new AnnotationEventBus();
  const server = await startHttpServer({ port: 0, version: '0.0.0', store, bus, logger: silentLogger });
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  const controller = new AbortController();
  const streamResponse = await fetch(`${base}/v1/rounds/stream`, { signal: controller.signal });
  assert.ok(streamResponse.body);

  try {
    const health = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(health.channelCount, 0);
    assert.equal(health.channelAttached, false);
  } finally {
    controller.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
