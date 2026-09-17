import assert from 'node:assert/strict';
import { test } from 'node:test';
import { uuidv7 } from './uuidv7.js';

const UUID_V7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test('uuidv7 produces a lowercase RFC 9562 v7 layout', () => {
  const id = uuidv7();
  assert.match(id, UUID_V7_RE);
});

test('uuidv7 ids from increasing timestamps sort ascending', () => {
  const earlier = uuidv7(1_700_000_000_000);
  const later = uuidv7(1_700_000_000_500);
  const sorted = [later, earlier].sort();
  assert.deepEqual(sorted, [earlier, later]);
});

test('uuidv7 ids are distinct even for the same millisecond', () => {
  const a = uuidv7(1_700_000_000_000);
  const b = uuidv7(1_700_000_000_000);
  assert.notEqual(a, b);
  assert.match(a, UUID_V7_RE);
  assert.match(b, UUID_V7_RE);
});
