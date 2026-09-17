import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { AnnotationMeta } from '../shared.js';
import { roundStatus, toRound, truncateUtf8 } from './rounds.js';

function baseMeta(overrides: Partial<AnnotationMeta> = {}): AnnotationMeta {
  return {
    id: 'ann-1',
    schemaVersion: 3,
    createdAt: '2026-01-01T00:00:00.000Z',
    claimedAt: null,
    servedAt: null,
    viewport: { w: 100, h: 200 },
    zoomRect: null,
    note: { text: null },
    sourceCaptureId: 'cap-1',
    device: { id: 'device-1', name: 'iPad' },
    reply: null,
    ...overrides,
  };
}

test('roundStatus is queued when unserved with no reply', () => {
  assert.equal(roundStatus(baseMeta()), 'queued');
});

test('roundStatus is sent when served with no reply', () => {
  assert.equal(roundStatus(baseMeta({ servedAt: '2026-01-01T00:00:01.000Z' })), 'sent');
});

test('roundStatus reflects the reply status regardless of servedAt, for all three reply outcomes', () => {
  for (const status of ['applied', 'failed', 'needs_input'] as const) {
    const meta = baseMeta({
      servedAt: '2026-01-01T00:00:01.000Z',
      reply: { status, message: null, prUrl: null, at: '2026-01-01T00:00:02.000Z' },
    });
    assert.equal(roundStatus(meta), status);
  }
});

test('truncateUtf8 leaves short ASCII text untouched', () => {
  assert.equal(truncateUtf8('hello', 2048), 'hello');
});

test('truncateUtf8 cuts long ASCII text to exactly maxBytes', () => {
  const truncated = truncateUtf8('a'.repeat(10), 4);
  assert.equal(truncated, 'aaaa');
  assert.equal(Buffer.byteLength(truncated, 'utf8'), 4);
});

test('truncateUtf8 never splits a multi-byte code point', () => {
  const text = `aa${'\u{1F600}'}`; // 2 ASCII bytes + a 4-byte emoji = 6 bytes total
  assert.equal(Buffer.byteLength(text, 'utf8'), 6);
  const truncated = truncateUtf8(text, 3);
  assert.equal(truncated, 'aa');
  assert.ok(Buffer.byteLength(truncated, 'utf8') <= 3);
});

test('truncateUtf8 with limit 0 returns an empty string', () => {
  assert.equal(truncateUtf8('anything', 0), '');
});

test('toRound omits absent fields for a fresh queued annotation', () => {
  const round = toRound(baseMeta());
  assert.deepEqual(round, {
    annotationId: 'ann-1',
    createdAt: '2026-01-01T00:00:00.000Z',
    status: 'queued',
  });
  assert.equal('message' in round, false);
  assert.equal('prUrl' in round, false);
  assert.equal('note' in round, false);
});

test('toRound carries note text and the reply message/prUrl, truncating a long message', () => {
  const round = toRound(
    baseMeta({
      note: { text: 'make it bigger' },
      servedAt: '2026-01-01T00:00:01.000Z',
      reply: {
        status: 'applied',
        message: 'x'.repeat(3000),
        prUrl: 'https://example.com/pr/1',
        at: '2026-01-01T00:00:02.000Z',
      },
    }),
  );
  assert.equal(round.status, 'applied');
  assert.equal(round.note, 'make it bigger');
  assert.equal(round.prUrl, 'https://example.com/pr/1');
  assert.equal(round.message?.length, 2048);
});
