import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  REPLY_TOOL,
  handleReplyCall,
  parseReplyArgs,
  type PostReply,
  type ReplyArgs,
} from './reply-tool.js';

test('REPLY_TOOL declares the expected name, required fields, and status enum', () => {
  assert.equal(REPLY_TOOL.name, 'design_canvas_reply');
  assert.deepEqual(REPLY_TOOL.inputSchema.required, ['annotation_id', 'status']);
  assert.deepEqual(REPLY_TOOL.inputSchema.properties.status.enum, [
    'applied',
    'failed',
    'needs_input',
  ]);
});

test('parseReplyArgs accepts the minimal form', () => {
  const result = parseReplyArgs({ annotation_id: 'abc123', status: 'applied' });
  assert.deepEqual(result, { annotationId: 'abc123', status: 'applied' });
});

test('parseReplyArgs accepts the full form', () => {
  const result = parseReplyArgs({
    annotation_id: 'abc123',
    status: 'failed',
    message: 'Could not find the button.',
    pr_url: 'https://github.com/example/repo/pull/1',
  });
  assert.deepEqual(result, {
    annotationId: 'abc123',
    status: 'failed',
    message: 'Could not find the button.',
    prUrl: 'https://github.com/example/repo/pull/1',
  });
});

test('parseReplyArgs rejects a missing annotation_id', () => {
  const result = parseReplyArgs({ status: 'applied' });
  assert.ok('error' in result);
});

test('parseReplyArgs rejects an empty (or whitespace-only) annotation_id', () => {
  assert.ok('error' in parseReplyArgs({ annotation_id: '', status: 'applied' }));
  assert.ok('error' in parseReplyArgs({ annotation_id: '   ', status: 'applied' }));
});

test('parseReplyArgs trims annotation_id', () => {
  const result = parseReplyArgs({ annotation_id: '  abc123  ', status: 'applied' });
  assert.deepEqual(result, { annotationId: 'abc123', status: 'applied' });
});

test('parseReplyArgs rejects a bad status', () => {
  const result = parseReplyArgs({ annotation_id: 'abc123', status: 'done' });
  assert.ok('error' in result);
});

test('parseReplyArgs rejects a missing status', () => {
  const result = parseReplyArgs({ annotation_id: 'abc123' });
  assert.ok('error' in result);
});

test('parseReplyArgs rejects a non-string message', () => {
  const result = parseReplyArgs({ annotation_id: 'abc123', status: 'applied', message: 42 });
  assert.ok('error' in result);
});

test('parseReplyArgs rejects a non-string pr_url', () => {
  const result = parseReplyArgs({ annotation_id: 'abc123', status: 'applied', pr_url: 42 });
  assert.ok('error' in result);
});

test('parseReplyArgs treats an empty message/pr_url as absent', () => {
  const result = parseReplyArgs({
    annotation_id: 'abc123',
    status: 'applied',
    message: '',
    pr_url: '',
  });
  assert.deepEqual(result, { annotationId: 'abc123', status: 'applied' });
});

test('parseReplyArgs ignores unknown extra keys', () => {
  const result = parseReplyArgs({
    annotation_id: 'abc123',
    status: 'applied',
    extra_field: 'ignore me',
  });
  assert.deepEqual(result, { annotationId: 'abc123', status: 'applied' });
});

test('parseReplyArgs rejects non-object input', () => {
  assert.ok('error' in parseReplyArgs(null));
  assert.ok('error' in parseReplyArgs('nope'));
  assert.ok('error' in parseReplyArgs(undefined));
});

function fakePost(result: Awaited<ReturnType<PostReply>>): {
  post: PostReply;
  calls: ReplyArgs[];
} {
  const calls: ReplyArgs[] = [];
  return {
    calls,
    post: async (args: ReplyArgs) => {
      calls.push(args);
      return result;
    },
  };
}

test('handleReplyCall: invalid args produce isError with the reason and never call post', async () => {
  const { post, calls } = fakePost({ ok: true });
  const result = await handleReplyCall({ status: 'applied' }, post);
  assert.equal(result.isError, true);
  assert.equal(calls.length, 0);
  assert.match(result.content[0].text, /annotation_id/);
});

test('handleReplyCall: 200 returns "Reply recorded."', async () => {
  const { post, calls } = fakePost({ ok: true });
  const result = await handleReplyCall({ annotation_id: 'abc123', status: 'applied' }, post);
  assert.equal(result.isError, undefined);
  assert.deepEqual(result.content, [{ type: 'text', text: 'Reply recorded.' }]);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], { annotationId: 'abc123', status: 'applied' });
});

test('handleReplyCall: 409 is isError "A reply was already recorded for this annotation."', async () => {
  const { post } = fakePost({ ok: false, status: 409, code: 'already_replied' });
  const result = await handleReplyCall({ annotation_id: 'abc123', status: 'applied' }, post);
  assert.equal(result.isError, true);
  assert.deepEqual(result.content, [
    { type: 'text', text: 'A reply was already recorded for this annotation.' },
  ]);
});

test('handleReplyCall: 404 is isError "Unknown annotation id."', async () => {
  const { post } = fakePost({ ok: false, status: 404, code: 'annotation_not_found' });
  const result = await handleReplyCall({ annotation_id: 'abc123', status: 'applied' }, post);
  assert.equal(result.isError, true);
  assert.deepEqual(result.content, [{ type: 'text', text: 'Unknown annotation id.' }]);
});

test('handleReplyCall: a network failure is isError and names the daemon', async () => {
  const { post } = fakePost({ ok: false, status: 0, code: 'network_error' });
  const result = await handleReplyCall({ annotation_id: 'abc123', status: 'applied' }, post);
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /daemon/i);
});

test('handleReplyCall passes a 5000-byte message through untruncated', async () => {
  const longMessage = 'x'.repeat(5000);
  const { post, calls } = fakePost({ ok: true });
  await handleReplyCall({ annotation_id: 'abc123', status: 'applied', message: longMessage }, post);
  assert.equal(calls[0]?.message?.length, 5000);
  assert.equal(calls[0]?.message, longMessage);
});
