import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createStorePaths } from './paths.js';

test('createStorePaths returns captures and annotations dirs', () => {
  const paths = createStorePaths();
  assert.ok(paths.captures.endsWith('captures'));
  assert.ok(paths.annotations.endsWith('annotations'));
});
