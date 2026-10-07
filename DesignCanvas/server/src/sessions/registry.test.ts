import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { SessionsSnapshot } from '../shared.js';
import { type RegisterInput, SessionRegistry } from './registry.js';

function make(startedAt = 0) {
  const changes: SessionsSnapshot[] = [];
  const logs: Array<{ type: string; fields: Record<string, unknown> }> = [];
  const registry = new SessionRegistry(
    { changed: (s) => changes.push(s), log: (type, fields) => logs.push({ type, fields }) },
    startedAt,
    5_000,
    15_000,
  );
  return { registry, changes, logs };
}

function session(instance: string, startedAt: string, extra: Partial<RegisterInput> = {}): RegisterInput {
  return { instance, sessionId: `sid-${instance}`, cwd: `/work/${instance}`, startedAt, ...extra };
}

const LATE = 60_000; // well past the settle window

test('a single session is the target, and its folder is the repo root name', () => {
  const { registry } = make();
  const result = registry.register(
    session('aaaaaaaa', '2026-10-05T10:00:00Z', { repoRoot: '/Users/me/code/acme-web' }),
    LATE,
  );
  assert.deepEqual(result, { target: true });
  assert.equal(registry.target, 'aaaaaaaa');
  assert.equal(registry.snapshot().sessions[0]?.folder, 'acme-web');
});

test('the target is sticky: a newer session does not take over (X22)', () => {
  const { registry } = make();
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), LATE);
  const second = registry.register(session('bbbbbbbb', '2026-10-05T11:00:00Z', { launch: 'n1' }), LATE);
  assert.deepEqual(second, { target: false });
  assert.equal(registry.target, 'aaaaaaaa');
});

test('while settling after a restart, the default goes to the launched session, else the newest', () => {
  const { registry } = make(0);
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), 1_000);
  assert.equal(registry.target, 'aaaaaaaa');
  registry.register(session('bbbbbbbb', '2026-10-05T11:00:00Z'), 1_500);
  assert.equal(registry.target, 'bbbbbbbb', 'newest wins while unsettled');
  registry.register(session('cccccccc', '2026-10-05T09:00:00Z', { launch: 'n1' }), 2_000);
  assert.equal(registry.target, 'cccccccc', 'a launched session outranks a newer one');
});

test('a session that was the target takes it back after a restart, and keeps it', () => {
  const { registry } = make(0);
  registry.register(session('aaaaaaaa', '2026-10-05T11:00:00Z', { launch: 'n1' }), 1_000);
  registry.register(session('bbbbbbbb', '2026-10-05T10:00:00Z', { wasTarget: true }), 1_500);
  assert.equal(registry.target, 'bbbbbbbb');
  registry.register(session('cccccccc', '2026-10-05T12:00:00Z', { launch: 'n2' }), 2_000);
  assert.equal(registry.target, 'bbbbbbbb', 'a restored target is not a revisable default');
});

test('a person\'s choice is not overridden by wasTarget or by a default', () => {
  const { registry } = make(0);
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), 1_000);
  registry.register(session('bbbbbbbb', '2026-10-05T11:00:00Z'), 1_200);
  assert.equal(registry.setTarget('aaaaaaaa', 'ipad'), true);
  registry.register(session('cccccccc', '2026-10-05T12:00:00Z', { wasTarget: true }), 1_500);
  assert.equal(registry.target, 'aaaaaaaa');
  assert.equal(registry.setTarget('nope-nope', 'mac'), false);
});

test('target ends: one session left takes over; several left means a pick (X26)', () => {
  const { registry } = make();
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), LATE);
  registry.register(session('bbbbbbbb', '2026-10-05T11:00:00Z'), LATE);
  registry.register(session('cccccccc', '2026-10-05T12:00:00Z'), LATE);
  registry.remove('aaaaaaaa', 'deregistered', LATE);
  assert.equal(registry.target, null, 'two remain: nobody is chosen');
  // A new session arriving does not resolve the pick either.
  registry.register(session('dddddddd', '2026-10-05T13:00:00Z'), LATE);
  assert.equal(registry.target, null);
  assert.equal(registry.setTarget('cccccccc', 'mac'), true);
  assert.equal(registry.target, 'cccccccc');

  registry.remove('bbbbbbbb', 'deregistered', LATE);
  registry.remove('dddddddd', 'deregistered', LATE);
  registry.remove('cccccccc', 'deregistered', LATE);
  assert.equal(registry.size, 0);
  registry.register(session('eeeeeeee', '2026-10-05T14:00:00Z'), LATE);
  registry.register(session('ffffffff', '2026-10-05T15:00:00Z'), LATE);
  registry.remove('eeeeeeee', 'deregistered', LATE);
  assert.equal(registry.target, 'ffffffff', 'one left takes over');
});

test('poll updates state and fields, reports changes once, and is null for an unknown instance', () => {
  const { registry, changes, logs } = make();
  assert.equal(registry.poll('aaaaaaaa', { state: 'idle' }, LATE), null);
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z', { title: 'old' }), LATE);
  const before = changes.length;
  assert.deepEqual(registry.poll('aaaaaaaa', { state: 'idle' }, LATE + 1_000), { target: true });
  assert.equal(changes.length, before, 'an unchanged poll announces nothing');
  registry.poll('aaaaaaaa', { state: 'waiting', sessionId: 'sid-2', branch: 'main', title: '' }, LATE + 2_000);
  assert.equal(changes.length, before + 1);
  const info = registry.get('aaaaaaaa');
  assert.equal(info?.state, 'waiting');
  assert.equal(info?.sessionId, 'sid-2');
  assert.equal(info?.branch, 'main');
  assert.equal(info?.title, undefined, 'an empty title clears it');
  assert.ok(logs.some((l) => l.type === 'session.state' && l.fields['state'] === 'waiting'));
});

test('sweep removes sessions that stopped polling, and only those', () => {
  const { registry, logs } = make();
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), LATE);
  registry.register(session('bbbbbbbb', '2026-10-05T11:00:00Z'), LATE);
  registry.poll('bbbbbbbb', { state: 'busy' }, LATE + 14_000);
  const removed = registry.sweep(LATE + 16_000);
  assert.deepEqual(removed.map((s) => s.instance), ['aaaaaaaa']);
  assert.equal(registry.target, 'bbbbbbbb');
  assert.ok(logs.some((l) => l.type === 'session.ended' && l.fields['cause'] === 'stale'));
});

test('re-registering keeps the session\'s state and its place', () => {
  const { registry } = make();
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z'), LATE);
  registry.poll('aaaaaaaa', { state: 'busy', lastReplyAt: '2026-10-05T10:05:00Z' }, LATE);
  registry.register(session('aaaaaaaa', '2026-10-05T10:00:00Z', { branch: 'feat' }), LATE);
  const info = registry.get('aaaaaaaa');
  assert.equal(info?.state, 'busy');
  assert.equal(info?.lastReplyAt, '2026-10-05T10:05:00Z');
  assert.equal(info?.branch, 'feat');
  assert.equal(registry.size, 1);
});
