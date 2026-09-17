import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { Round } from '../shared.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { startHttpServer } from './server.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function withStore(
  run: (store: DesignCanvasStore, base: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), 'dc-rounds-'));
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

async function seedAnnotation(
  store: DesignCanvasStore,
  deviceId: string,
  createdAt: string,
): Promise<string> {
  const capture = await store.createCapture({ screenshot: Buffer.from('p'), viewport: { w: 1, h: 1 } });
  const ann = await store.createAnnotation({
    composite: Buffer.from('c'),
    sketch: Buffer.from('s'),
    sourceCaptureId: capture.id,
    viewport: { w: 1, h: 1 },
    zoomRect: null,
    device: { id: deviceId, name: 'iPad' },
    createdAt,
  });
  return ann.id;
}

test('GET /v1/rounds without device returns 400', async () => {
  await withStore(async (_store, base) => {
    const response = await fetch(`${base}/v1/rounds?limit=5`);
    assert.equal(response.status, 400);
  });
});

test('GET /v1/rounds filters by device and orders newest first', async () => {
  await withStore(async (store, base) => {
    const idOld = await seedAnnotation(store, 'device-a', '2026-01-01T00:00:00.000Z');
    const idNew = await seedAnnotation(store, 'device-a', '2026-01-02T00:00:00.000Z');
    await seedAnnotation(store, 'device-b', '2026-01-03T00:00:00.000Z');

    const response = await fetch(`${base}/v1/rounds?device=device-a`);
    assert.equal(response.status, 200);
    const { rounds } = (await response.json()) as { rounds: Round[] };
    assert.equal(rounds.length, 2);
    assert.equal(rounds[0]?.annotationId, idNew);
    assert.equal(rounds[1]?.annotationId, idOld);
  });
});

test('GET /v1/rounds caps at 20 when 25 are stored, and clamps an over-large limit', async () => {
  await withStore(async (store, base) => {
    for (let i = 0; i < 25; i += 1) {
      const createdAt = new Date(2026, 0, 1, 0, 0, i).toISOString();
      await seedAnnotation(store, 'device-a', createdAt);
    }
    const response = await fetch(`${base}/v1/rounds?device=device-a&limit=9999`);
    assert.equal(response.status, 200);
    const { rounds } = (await response.json()) as { rounds: Round[] };
    assert.equal(rounds.length, 20);
  });
});

test('GET /v1/rounds rejects a non-numeric or sub-1 limit with 400', async () => {
  await withStore(async (store, base) => {
    await seedAnnotation(store, 'device-a', '2026-01-01T00:00:00.000Z');
    const nonNumeric = await fetch(`${base}/v1/rounds?device=device-a&limit=abc`);
    assert.equal(nonNumeric.status, 400);
    const zero = await fetch(`${base}/v1/rounds?device=device-a&limit=0`);
    assert.equal(zero.status, 400);
    const negative = await fetch(`${base}/v1/rounds?device=device-a&limit=-1`);
    assert.equal(negative.status, 400);
  });
});

test('GET /v1/rounds truncates a long reply message to at most 2048 bytes', async () => {
  await withStore(async (store, base) => {
    const id = await seedAnnotation(store, 'device-a', '2026-01-01T00:00:00.000Z');
    await store.setReply(id, { status: 'applied', message: 'z'.repeat(5000), prUrl: null });

    const response = await fetch(`${base}/v1/rounds?device=device-a`);
    const { rounds } = (await response.json()) as { rounds: Round[] };
    assert.equal(rounds[0]?.annotationId, id);
    assert.ok((rounds[0]?.message?.length ?? 0) <= 2048);
  });
});
