import assert from 'node:assert/strict';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { test } from 'node:test';
import { requireLoopback } from './server.js';

function fakeRequest(remoteAddress: string | undefined): IncomingMessage {
  return { socket: { remoteAddress } } as unknown as IncomingMessage;
}

function fakeResponse(): { response: ServerResponse; writes: { statusCode: number; body: string }[] } {
  const writes: { statusCode: number; body: string }[] = [];
  const response = {
    writeHead(statusCode: number) {
      writes.push({ statusCode, body: '' });
      return response;
    },
    end(body?: string) {
      if (writes.length > 0 && typeof body === 'string') {
        writes[writes.length - 1]!.body = body;
      }
    },
  } as unknown as ServerResponse;
  return { response, writes };
}

test('requireLoopback allows a loopback peer and writes nothing', () => {
  const { response, writes } = fakeResponse();
  const allowed = requireLoopback(fakeRequest('127.0.0.1'), response);
  assert.equal(allowed, true);
  assert.equal(writes.length, 0);
});

test('requireLoopback rejects a non-loopback peer with 403 forbidden', () => {
  const { response, writes } = fakeResponse();
  const allowed = requireLoopback(fakeRequest('192.168.1.50'), response);
  assert.equal(allowed, false);
  assert.equal(writes.length, 1);
  assert.equal(writes[0]?.statusCode, 403);
  assert.deepEqual(JSON.parse(writes[0]?.body ?? '{}'), {
    error: 'forbidden',
    message: 'Loopback only.',
  });
});

test('requireLoopback rejects when the socket has no remote address', () => {
  const { response, writes } = fakeResponse();
  const allowed = requireLoopback(fakeRequest(undefined), response);
  assert.equal(allowed, false);
  assert.equal(writes[0]?.statusCode, 403);
});
