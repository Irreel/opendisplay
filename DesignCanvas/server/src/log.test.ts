import assert from 'node:assert/strict';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { defaultLogPath } from './log.js';

test('defaultLogPath points at ~/Library/Logs/DesignCanvas/server.log when unset', () => {
  const previous = process.env['DESIGN_CANVAS_LOG_PATH'];
  delete process.env['DESIGN_CANVAS_LOG_PATH'];
  try {
    assert.equal(
      defaultLogPath(),
      join(homedir(), 'Library', 'Logs', 'DesignCanvas', 'server.log'),
    );
  } finally {
    if (previous !== undefined) process.env['DESIGN_CANVAS_LOG_PATH'] = previous;
  }
});

test('defaultLogPath honors DESIGN_CANVAS_LOG_PATH when set', () => {
  const previous = process.env['DESIGN_CANVAS_LOG_PATH'];
  process.env['DESIGN_CANVAS_LOG_PATH'] = '/tmp/dc-test.log';
  try {
    assert.equal(defaultLogPath(), '/tmp/dc-test.log');
  } finally {
    if (previous === undefined) delete process.env['DESIGN_CANVAS_LOG_PATH'];
    else process.env['DESIGN_CANVAS_LOG_PATH'] = previous;
  }
});
