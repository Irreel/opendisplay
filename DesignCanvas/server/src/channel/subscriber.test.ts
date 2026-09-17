import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { AnnotationEventBus } from '../http/event-stream.js';
import { startHttpServer } from '../http/server.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import type { ChannelNotifier } from './index.js';
import { runChannelSubscriber } from './subscriber.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) {
      throw new Error('waitFor timed out');
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

async function postCapture(base: string): Promise<string> {
  const response = await fetch(`${base}/v1/captures`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      screenshotBase64: Buffer.from('png').toString('base64'),
      viewport: { w: 100, h: 200 },
    }),
  });
  assert.equal(response.status, 201);
  const { captureId } = (await response.json()) as { captureId: string };
  return captureId;
}

async function postAnnotation(base: string, captureId: string): Promise<string> {
  const response = await fetch(`${base}/v1/annotations`, {
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
  assert.equal(response.status, 201);
  const { annotationId } = (await response.json()) as { annotationId: string };
  return annotationId;
}

test('subscriber claims a pending annotation, notifies, and marks it served', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-subscriber-'));
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
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  const notified: { id: string; capturedAt: string }[] = [];
  const fakeChannel = {
    attached: true,
    notifyAnnotation: async (a: { meta: { id: string }; capturedAt: string }) => {
      notified.push({ id: a.meta.id, capturedAt: a.capturedAt });
    },
  } as unknown as ChannelNotifier;

  const controller = new AbortController();
  void runChannelSubscriber({ baseUrl: base, channel: fakeChannel, logger: silentLogger, signal: controller.signal });

  try {
    const captureId = await postCapture(base);
    const annotationId = await postAnnotation(base, captureId);

    await waitFor(() => notified.length === 1, 3000);
    assert.deepEqual(notified.map((n) => n.id), [annotationId]);
    // The claim response's capturedAt (Task 6) is passed through to notifyAnnotation.
    assert.equal(typeof notified[0]?.capturedAt, 'string');
    assert.ok((notified[0]?.capturedAt.length ?? 0) > 0);

    // The annotation is now served — a re-claim must 409.
    const reclaim = await fetch(`${base}/v1/annotations/${annotationId}/claim`, { method: 'POST' });
    assert.equal(reclaim.status, 409);

    const list = await fetch(`${base}/v1/annotations`);
    const { annotations } = (await list.json()) as {
      annotations: { id: string; servedAt: string | null }[];
    };
    const found = annotations.find((a) => a.id === annotationId);
    assert.ok(found);
    assert.notEqual(found.servedAt, null);
  } finally {
    controller.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('subscriber replays backlog: a pre-existing pending annotation is delivered on connect', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-subscriber-backlog-'));
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
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  // Create a pending annotation BEFORE any subscriber attaches. This sits in the
  // backlog with no live SSE event, so the only way it gets delivered is via
  // replayBacklog on connect — deterministic, no reconnect/timing dependence.
  const captureId = await postCapture(base);
  const annotationId = await postAnnotation(base, captureId);

  const notified: string[] = [];
  const fakeChannel = {
    attached: true,
    notifyAnnotation: async (a: { meta: { id: string } }) => {
      notified.push(a.meta.id);
    },
  } as unknown as ChannelNotifier;

  const controller = new AbortController();
  void runChannelSubscriber({ baseUrl: base, channel: fakeChannel, logger: silentLogger, signal: controller.signal });

  try {
    await waitFor(() => notified.length === 1, 3000);
    assert.deepEqual(notified, [annotationId]);

    // Backlog item is now served — re-claim must 409.
    const reclaim = await fetch(`${base}/v1/annotations/${annotationId}/claim`, { method: 'POST' });
    assert.equal(reclaim.status, 409);

    const list = await fetch(`${base}/v1/annotations`);
    const { annotations } = (await list.json()) as {
      annotations: { id: string; servedAt: string | null }[];
    };
    const found = annotations.find((a) => a.id === annotationId);
    assert.ok(found);
    assert.notEqual(found.servedAt, null);
  } finally {
    controller.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('two subscribers produce exactly one notification per annotation', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-subscriber-two-'));
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
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  const counts = new Map<string, number>();
  const record = (id: string) => counts.set(id, (counts.get(id) ?? 0) + 1);
  const channelA = {
    attached: true,
    notifyAnnotation: async (a: { meta: { id: string } }) => record(a.meta.id),
  } as unknown as ChannelNotifier;
  const channelB = {
    attached: true,
    notifyAnnotation: async (a: { meta: { id: string } }) => record(a.meta.id),
  } as unknown as ChannelNotifier;

  const controllerA = new AbortController();
  const controllerB = new AbortController();
  void runChannelSubscriber({ baseUrl: base, channel: channelA, logger: silentLogger, signal: controllerA.signal });
  void runChannelSubscriber({ baseUrl: base, channel: channelB, logger: silentLogger, signal: controllerB.signal });

  try {
    const captureId = await postCapture(base);
    const annotationId = await postAnnotation(base, captureId);

    await waitFor(() => counts.get(annotationId) === 1, 3000);
    // Give any losing claimant a moment to (not) double-notify.
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert.equal(counts.get(annotationId), 1);
  } finally {
    controllerA.abort();
    controllerB.abort();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
