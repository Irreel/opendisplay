import assert from 'node:assert/strict';
import { request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http';
import { mkdtemp } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { DesignCanvasStore } from '../store/store.js';
import { createStorePaths } from '../store/paths.js';
import { AnnotationEventBus } from './event-stream.js';
import { allowedHost, requireLoopback, startHttpServer } from './server.js';

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

// Binding to loopback does not stop a browser: a page on any site can be made to
// resolve its own hostname to 127.0.0.1 (DNS rebinding) and then talk to the daemon
// as same-origin — posting a capture plus an annotation with an attacker's note and
// image, which is prompt injection into the user's Claude Code session, or reading
// GET /v1/annotations. The Host and Origin checks are what stop that (I4).

test('allowedHost accepts only the loopback names on the bound port', () => {
  assert.equal(allowedHost('127.0.0.1:47100', 47100), true);
  assert.equal(allowedHost('localhost:47100', 47100), true);
  assert.equal(allowedHost('[::1]:47100', 47100), true);
  assert.equal(allowedHost('evil.test:47100', 47100), false);
  assert.equal(allowedHost('127.0.0.1.evil.test:47100', 47100), false);
  assert.equal(allowedHost('127.0.0.1:47101', 47100), false, 'a different port is a different daemon');
  assert.equal(allowedHost('127.0.0.1', 47100), false, 'the port is part of the expectation');
  assert.equal(allowedHost(undefined, 47100), false);
  assert.equal(allowedHost('', 47100), false);
});

interface RawResponse {
  statusCode: number;
  body: string;
}

/** One request with headers `fetch` refuses to set (notably Host). */
function rawGet(port: number, path: string, headers: Record<string, string>): Promise<RawResponse> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: '127.0.0.1', port, path, method: 'GET', headers }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk: string) => {
        body += chunk;
      });
      res.on('end', () => resolve({ statusCode: res.statusCode ?? 0, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

const silentLogger = { event: async () => {} } as unknown as ConstructorParameters<
  typeof DesignCanvasStore
>[0];

async function withServer(run: (port: number) => Promise<void>): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), 'dc-guard-'));
  const store = new DesignCanvasStore(silentLogger, createStorePaths(root));
  await store.ensure();
  const server = await startHttpServer({
    port: 0,
    version: '0.0.0',
    store,
    bus: new AnnotationEventBus(),
    logger: silentLogger,
  });
  try {
    await run((server.address() as AddressInfo).port);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

test('a request naming the daemon by a loopback Host is served', async () => {
  await withServer(async (port) => {
    for (const host of [`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`]) {
      const response = await rawGet(port, '/v1/health', { host });
      assert.equal(response.statusCode, 200, host);
    }
  });
});

test('a request with a foreign Host is refused with 403 forbidden', async () => {
  await withServer(async (port) => {
    const response = await rawGet(port, '/v1/health', { host: `rebind.attacker.test:${port}` });
    assert.equal(response.statusCode, 403);
    assert.equal(JSON.parse(response.body).error, 'forbidden');
  });
});

test('a request carrying an Origin header is refused, however good its Host', async () => {
  await withServer(async (port) => {
    const health = await rawGet(port, '/v1/health', {
      host: `127.0.0.1:${port}`,
      origin: 'https://attacker.test',
    });
    assert.equal(health.statusCode, 403);
    assert.equal(JSON.parse(health.body).error, 'forbidden');

    // The read path a page would want just as much as the write one.
    const list = await rawGet(port, '/v1/annotations', {
      host: `127.0.0.1:${port}`,
      origin: 'null',
    });
    assert.equal(list.statusCode, 403);
  });
});
