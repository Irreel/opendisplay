import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AnnotationMeta, RoundEvent, SessionsSnapshot } from '../shared.js';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { RoundsEventBus } from './rounds-stream.js';
import { closeRoundsOfEndedSessions, createSessionRegistry, startHttpServer } from './server.js';
import { SessionsEventBus } from '../sessions/sessions-stream.js';

const events: Array<{ type: string; fields?: Record<string, unknown> }> = [];
const logger = {
  event: async (type: string, fields?: Record<string, unknown>) => {
    events.push(fields ? { type, fields } : { type });
  },
};

async function start() {
  const root = await mkdtemp(join(tmpdir(), 'dc-sessions-http-'));
  const store = new DesignCanvasStore(logger, createStorePaths(root));
  await store.ensure();
  const roundsBus = new RoundsEventBus();
  const sessionsBus = new SessionsEventBus();
  // Started long ago, so the settle window is over and targets are sticky.
  const sessions = createSessionRegistry(logger, sessionsBus, Date.now() - 60_000);
  const rounds: RoundEvent[] = [];
  roundsBus.subscribe((event) => rounds.push(event));
  const server = await startHttpServer({
    port: 0,
    version: '0.0.0',
    store,
    bus: new AnnotationEventBus(),
    roundsBus,
    sessions,
    sessionsBus,
    logger,
  });
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;
  const json = async (method: string, path: string, body?: unknown) => {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: { 'content-type': 'application/json' },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    return { status: response.status, body: (await response.json()) as Record<string, unknown> };
  };
  const register = (instance: string, extra: Record<string, unknown> = {}) =>
    json('POST', '/v1/sessions', {
      instance,
      sessionId: `sid-${instance}`,
      cwd: `/work/${instance}`,
      startedAt: new Date().toISOString(),
      ...extra,
    });
  const poll = (instance: string, body: Record<string, unknown>) =>
    json('POST', `/v1/sessions/${instance}/poll`, body);
  const sketch = async (extra: Record<string, unknown> = {}) => {
    const capture = await json('POST', '/v1/captures', {
      screenshotBase64: Buffer.from('png').toString('base64'),
      viewport: { w: 100, h: 200 },
    });
    const annotation = await json('POST', '/v1/annotations', {
      compositeBase64: Buffer.from('composite').toString('base64'),
      sketchBase64: Buffer.from('sketch').toString('base64'),
      sourceCaptureId: capture.body['captureId'],
      viewport: { w: 100, h: 200 },
      zoomRect: null,
      device: { id: 'device-1', name: 'iPad' },
      ...extra,
    });
    return annotation;
  };
  const meta = async (id: string): Promise<AnnotationMeta> => {
    const list = await json('GET', '/v1/annotations');
    const found = (list.body['annotations'] as AnnotationMeta[]).find((a) => a.id === id);
    assert.ok(found, `annotation ${id} exists`);
    return found;
  };
  return { server, store, sessions, roundsBus, rounds, base, json, register, poll, sketch, meta };
}

type Claimed = { meta: AnnotationMeta; compositePath: string; capturedAt: string };

test('a session registers, is polled a round in order, serves it and replies', async () => {
  const t = await start();
  try {
    assert.equal((await t.poll('aaaaaaaa1', { state: 'idle', want: true })).status, 404);
    const registered = await t.register('aaaaaaaa1', { repoRoot: '/code/acme' });
    assert.deepEqual(registered.body, { target: true });
    const health = await t.json('GET', '/v1/health');
    assert.equal(health.body['sessionCount'], 1);

    const first = await t.sketch();
    const second = await t.sketch();
    assert.equal(first.body['dispatched'], true);
    const firstId = first.body['annotationId'] as string;
    const secondId = second.body['annotationId'] as string;
    assert.deepEqual((await t.meta(firstId)).session, {
      instance: 'aaaaaaaa1',
      sessionId: 'sid-aaaaaaaa1',
      folder: 'acme',
    });

    // Not idle, or not asking: no round.
    assert.equal((await t.poll('aaaaaaaa1', { state: 'busy', want: true })).body['round'], undefined);
    assert.equal((await t.poll('aaaaaaaa1', { state: 'idle' })).body['round'], undefined);

    const polled = await t.poll('aaaaaaaa1', { state: 'idle', want: true });
    const round = polled.body['round'] as Claimed;
    assert.equal(round.meta.id, firstId, 'oldest first');
    assert.equal(typeof round.compositePath, 'string');
    // The channel's claim is refused a round that belongs to a session.
    assert.equal((await t.json('POST', `/v1/annotations/${firstId}/claim`)).status, 409);
    // Asking again before it is served hands the same round back, not the next.
    const again = await t.poll('aaaaaaaa1', { state: 'idle', want: true });
    assert.equal((again.body['round'] as Claimed).meta.id, firstId);

    assert.equal((await t.json('POST', `/v1/annotations/${firstId}/served`)).status, 200);
    assert.equal((await t.json('POST', `/v1/annotations/${firstId}/reminded`)).status, 200);
    assert.equal(typeof (await t.meta(firstId)).remindedAt, 'string');
    const reply = await t.json('POST', `/v1/annotations/${firstId}/reply`, {
      status: 'failed',
      message: 'Claude did not reply to this sketch.',
      reason: 'no_reply',
    });
    assert.equal(reply.status, 200);
    assert.equal((await t.meta(firstId)).reply?.reason, 'no_reply');
    assert.equal(
      (await t.json('POST', `/v1/annotations/${secondId}/reply`, { status: 'failed', reason: 'bored' })).status,
      400,
    );

    const next = await t.poll('aaaaaaaa1', { state: 'idle', want: true });
    assert.equal((next.body['round'] as Claimed).meta.id, secondId);
    assert.equal((await t.json('POST', '/v1/annotations/nope/reminded')).status, 404);
  } finally {
    t.server.close();
  }
});

test('a sketch sent with no session waits unbound and goes to the target only', async () => {
  const t = await start();
  try {
    const sent = await t.sketch();
    const id = sent.body['annotationId'] as string;
    assert.equal(sent.body['dispatched'], false);
    assert.equal((await t.meta(id)).session, undefined);

    await t.register('aaaaaaaa1');
    await t.register('bbbbbbbb1');
    assert.equal((await t.poll('bbbbbbbb1', { state: 'idle', want: true })).body['round'], undefined);
    const polled = await t.poll('aaaaaaaa1', { state: 'idle', want: true });
    assert.equal((polled.body['round'] as Claimed).meta.id, id);
    assert.equal((await t.meta(id)).session?.instance, 'aaaaaaaa1');
  } finally {
    t.server.close();
  }
});

test('a sketch names its session; switching the target moves the next one, not this one (X23)', async () => {
  const t = await start();
  try {
    await t.register('aaaaaaaa1');
    await t.register('bbbbbbbb1');
    const forB = await t.sketch({ session: 'bbbbbbbb1' });
    const forTarget = await t.sketch();
    const switched = await t.json('PUT', '/v1/sessions/target', { instance: 'bbbbbbbb1', by: 'ipad' });
    assert.equal((switched.body as unknown as SessionsSnapshot).target, 'bbbbbbbb1');
    assert.equal((await t.meta(forTarget.body['annotationId'] as string)).session?.instance, 'aaaaaaaa1');
    const polledB = await t.poll('bbbbbbbb1', { state: 'idle', want: true });
    assert.equal((polledB.body['round'] as Claimed).meta.id, forB.body['annotationId']);
    assert.equal((await t.json('PUT', '/v1/sessions/target', { instance: 'zzzzzzzz1' })).status, 404);
    assert.equal((await t.sketch({ session: '../x' })).status, 400);
  } finally {
    t.server.close();
  }
});

test('ending a session fails its unanswered rounds and announces them (X26)', async () => {
  const t = await start();
  try {
    await t.register('aaaaaaaa1');
    const queued = await t.sketch();
    const inFlight = await t.sketch();
    const answered = await t.sketch();
    const answeredId = answered.body['annotationId'] as string;
    await t.json('POST', `/v1/annotations/${answeredId}/reply`, { status: 'applied' });
    t.rounds.length = 0;

    assert.equal((await t.json('DELETE', '/v1/sessions/aaaaaaaa1')).status, 200);
    assert.equal((await t.json('DELETE', '/v1/sessions/aaaaaaaa1')).status, 404);
    for (const sent of [queued, inFlight]) {
      const reply = (await t.meta(sent.body['annotationId'] as string)).reply;
      assert.equal(reply?.status, 'failed');
      assert.equal(reply?.reason, 'session_ended');
    }
    assert.equal((await t.meta(answeredId)).reply?.status, 'applied');
    assert.equal(t.rounds.filter((r) => r.status === 'failed').length, 2);

    // A sketch drawn for a session that ended before it arrived is failed at once.
    const late = await t.sketch({ session: 'aaaaaaaa1' });
    assert.equal(late.status, 201);
    assert.equal(late.body['dispatched'], false);
    assert.equal((await t.meta(late.body['annotationId'] as string)).reply?.reason, 'session_ended');
  } finally {
    t.server.close();
  }
});

test('rounds bound to a session that never came back are closed by the orphan check', async () => {
  const t = await start();
  try {
    await t.register('aaaaaaaa1');
    await t.register('bbbbbbbb1');
    const mine = await t.sketch({ session: 'aaaaaaaa1' });
    const theirs = await t.sketch({ session: 'bbbbbbbb1' });
    // Simulate the daemon forgetting 'a' without the DELETE path (a restart).
    t.sessions.sweep(Date.now() + 60_000);
    await t.register('bbbbbbbb1');
    const closed = await closeRoundsOfEndedSessions({
      store: t.store,
      roundsBus: t.roundsBus,
      gone: (instance) => !t.sessions.has(instance),
    });
    assert.equal(closed, 1);
    assert.equal((await t.meta(mine.body['annotationId'] as string)).reply?.reason, 'session_ended');
    assert.equal((await t.meta(theirs.body['annotationId'] as string)).reply, null);
  } finally {
    t.server.close();
  }
});

test('the sessions list, its stream, and input validation', async () => {
  const t = await start();
  try {
    assert.equal((await t.register('short')).status, 400);
    assert.equal((await t.register('aaaaaaaa1', { startedAt: 'yesterday' })).status, 400);
    await t.register('aaaaaaaa1', { title: 'fix header', branch: 'main', launch: 'nonce' });
    assert.equal((await t.poll('aaaaaaaa1', { state: 'asleep' })).status, 400);
    await t.poll('aaaaaaaa1', { state: 'waiting' });
    const list = (await t.json('GET', '/v1/sessions')).body as unknown as SessionsSnapshot;
    assert.equal(list.target, 'aaaaaaaa1');
    assert.equal(list.sessions[0]?.state, 'waiting');
    assert.equal(list.sessions[0]?.title, 'fix header');

    const controller = new AbortController();
    const stream = await fetch(`${t.base}/v1/sessions/stream`, { signal: controller.signal });
    const reader = stream.body!.getReader();
    let text = '';
    while (!text.includes('sessions.updated')) {
      const { value, done } = await reader.read();
      if (done) break;
      text += new TextDecoder().decode(value);
    }
    controller.abort();
    assert.match(text, /event: sessions\.updated\ndata: \{"sessions":\[\{"instance":"aaaaaaaa1"/);
  } finally {
    t.server.close();
  }
});
