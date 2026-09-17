import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { HealthResponse } from '../shared.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { startHttpServer } from './server.js';

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function waitFor(predicate: () => boolean | Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await predicate())) {
    if (Date.now() > deadline) {
      throw new Error('waitFor timed out');
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

async function withServer(
  run: (base: string, bus: AnnotationEventBus) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), 'dc-health-'));
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
    await run(`http://127.0.0.1:${port}`, bus);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

test('/v1/health reports daemon identity, a stable instanceId, and the bound port', async () => {
  await withServer(async (base) => {
    const first = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    const second = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;

    assert.equal(first.status, 'ok');
    assert.equal(first.pid, process.pid);
    assert.match(first.instanceId ?? '', UUID_RE);
    assert.equal(typeof first.startedAt, 'string');
    assert.equal(typeof first.serverEntry, 'string');
    assert.ok((first.serverEntry ?? '').length > 0);
    const expectedPort = Number(new URL(base).port);
    assert.equal(first.port, expectedPort);

    assert.equal(second.instanceId, first.instanceId);
  });
});

test('/v1/health channelCount and channelAttachedAt track live SSE subscribers', async () => {
  await withServer(async (base) => {
    const idle = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(idle.channelCount, 0);
    assert.equal(idle.channelAttachedAt ?? null, null);
    assert.equal(idle.channelAttached, false);

    const controllerA = new AbortController();
    const streamA = await fetch(`${base}/v1/annotations/stream`, { signal: controllerA.signal });
    assert.ok(streamA.body);

    await waitFor(async () => {
      const health = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
      return health.channelCount === 1;
    }, 2000);

    const afterFirst = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(afterFirst.channelCount, 1);
    assert.equal(afterFirst.channelAttached, true);
    assert.equal(typeof afterFirst.channelAttachedAt, 'string');
    const firstAttachedAt = afterFirst.channelAttachedAt;

    await new Promise((resolve) => setTimeout(resolve, 5));
    const controllerB = new AbortController();
    const streamB = await fetch(`${base}/v1/annotations/stream`, { signal: controllerB.signal });
    assert.ok(streamB.body);

    await waitFor(async () => {
      const health = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
      return health.channelCount === 2;
    }, 2000);

    const afterSecond = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(afterSecond.channelCount, 2);
    // The oldest attach time is unchanged: subscriber A is still oldest.
    assert.equal(afterSecond.channelAttachedAt, firstAttachedAt);

    controllerA.abort();
    await waitFor(async () => {
      const health = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
      return health.channelCount === 1;
    }, 2000);

    const afterFirstLeft = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(afterFirstLeft.channelCount, 1);
    // Subscriber B is now the oldest surviving subscriber, attached later than A.
    assert.notEqual(afterFirstLeft.channelAttachedAt, firstAttachedAt);
    assert.equal(typeof afterFirstLeft.channelAttachedAt, 'string');

    controllerB.abort();
    await waitFor(async () => {
      const health = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
      return health.channelCount === 0;
    }, 2000);

    const empty = (await (await fetch(`${base}/v1/health`)).json()) as HealthResponse;
    assert.equal(empty.channelCount, 0);
    assert.equal(empty.channelAttachedAt ?? null, null);
    assert.equal(empty.channelAttached, false);
  });
});

test('/v1/health has no ipadUrls or pairedDevices, and the daemon binds 127.0.0.1', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dc-health-bind-'));
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
    const address = server.address() as AddressInfo;
    assert.equal(address.address, '127.0.0.1');
    const { port } = address;
    const health = (await (
      await fetch(`http://127.0.0.1:${port}/v1/health`)
    ).json()) as Record<string, unknown>;
    assert.equal('ipadUrls' in health, false);
    assert.equal('pairedDevices' in health, false);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('GET /v1/captures/latest no longer exists (404)', async () => {
  await withServer(async (base) => {
    const response = await fetch(`${base}/v1/captures/latest`);
    assert.equal(response.status, 404);
  });
});
