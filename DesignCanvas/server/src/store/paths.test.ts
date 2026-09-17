import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createStorePaths, defaultStoreRoot } from './paths.js';

test('createStorePaths returns captures and annotations dirs', () => {
  const paths = createStorePaths();
  assert.ok(paths.captures.endsWith('captures'));
  assert.ok(paths.annotations.endsWith('annotations'));
});

test('defaultStoreRoot points at ~/.claude/channels/design-canvas when unset', () => {
  const previous = process.env['DESIGN_CANVAS_STORE_DIR'];
  delete process.env['DESIGN_CANVAS_STORE_DIR'];
  try {
    assert.equal(defaultStoreRoot(), join(homedir(), '.claude', 'channels', 'design-canvas'));
  } finally {
    if (previous !== undefined) process.env['DESIGN_CANVAS_STORE_DIR'] = previous;
  }
});
