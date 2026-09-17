import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { Notification } from '@modelcontextprotocol/sdk/types.js';
import type { Logger } from '../log.js';
import type { AnnotationMeta } from '../shared.js';
import type { PostReply, ReplyArgs } from './reply-tool.js';
import { createInstructionText, createMcpChannel, type ClaimedAnnotation } from './index.js';

const silentLogger: Logger = { event: async () => {} };

async function makeCompositePath(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'dc-channel-index-'));
  const path = join(dir, 'composite.png');
  await writeFile(path, Buffer.from('fake-png'));
  return path;
}

function baseMeta(overrides: Partial<AnnotationMeta> = {}): AnnotationMeta {
  return {
    id: 'ann-1',
    schemaVersion: 3,
    createdAt: '2026-01-01T00:00:00.000Z',
    claimedAt: '2026-01-01T00:00:01.000Z',
    servedAt: null,
    viewport: { w: 100, h: 200 },
    zoomRect: null,
    note: { text: null },
    sourceCaptureId: 'cap-1',
    device: { id: 'dev-1', name: 'iPad Pro' },
    reply: null,
    ...overrides,
  };
}

async function connectedPair(postReply: PostReply) {
  const [serverTransport, clientTransport] = InMemoryTransport.createLinkedPair();
  const channel = createMcpChannel(silentLogger, { transport: serverTransport, postReply });
  const client = new Client({ name: 'test-client', version: '0.0.0' });
  await Promise.all([channel.connect(), client.connect(clientTransport)]);
  return { channel, client };
}

test('createInstructionText renders the exact v3 template for a zoomed annotation', async () => {
  const compositePath = await makeCompositePath();
  const annotation: ClaimedAnnotation = {
    meta: baseMeta({
      zoomRect: { x: 0.25, y: 0.1, w: 0.5, h: 0.4 },
      note: { text: '  Make the button bigger.  ' },
    }),
    compositePath,
    capturedAt: '2026-01-01T00:00:00.500Z',
  };
  const text = createInstructionText(annotation);
  assert.equal(
    text,
    [
      'New annotation from iPad.',
      'Annotation ID: ann-1',
      'Device: iPad Pro',
      'Captured at: 2026-01-01T00:00:00.500Z',
      'Sent at: 2026-01-01T00:00:00.000Z',
      `Composite PNG path: ${compositePath}`,
      'Zoom region: x=0.250 y=0.100 w=0.500 h=0.400',
      'Note: Make the button bigger.',
      '',
      'Inspect the composite PNG path to see the visual annotation.',
      'Apply this annotation to the source code, then call design_canvas_reply with the outcome.',
    ].join('\n'),
  );
});

test('createInstructionText renders "full frame" and "(none)" for a full-frame, note-less annotation', async () => {
  const compositePath = await makeCompositePath();
  const annotation: ClaimedAnnotation = {
    meta: baseMeta({ zoomRect: null, note: { text: null } }),
    compositePath,
    capturedAt: '2026-01-01T00:00:00.500Z',
  };
  const text = createInstructionText(annotation);
  assert.equal(
    text,
    [
      'New annotation from iPad.',
      'Annotation ID: ann-1',
      'Device: iPad Pro',
      'Captured at: 2026-01-01T00:00:00.500Z',
      'Sent at: 2026-01-01T00:00:00.000Z',
      `Composite PNG path: ${compositePath}`,
      'Zoom region: full frame',
      'Note: (none)',
      '',
      'Inspect the composite PNG path to see the visual annotation.',
      'Apply this annotation to the source code, then call design_canvas_reply with the outcome.',
    ].join('\n'),
  );
});

test('createInstructionText renders "unknown iPad" for an empty device name', async () => {
  const compositePath = await makeCompositePath();
  const annotation: ClaimedAnnotation = {
    meta: baseMeta({ device: { id: '', name: '' } }),
    compositePath,
    capturedAt: '2026-01-01T00:00:00.500Z',
  };
  const text = createInstructionText(annotation);
  assert.match(text, /^Device: unknown iPad$/m);
});

test('listTools returns exactly one tool named design_canvas_reply with the status enum', async () => {
  const { client, channel } = await connectedPair(async () => ({ ok: true }));
  try {
    const result = await client.listTools();
    assert.equal(result.tools.length, 1);
    const tool = result.tools[0];
    assert.equal(tool?.name, 'design_canvas_reply');
    const properties = tool?.inputSchema.properties as Record<string, { enum?: string[] }>;
    assert.deepEqual(properties['status']?.enum, ['applied', 'failed', 'needs_input']);
  } finally {
    await client.close();
    void channel;
  }
});

test('callTool reaches the injected postReply with mapped camelCase args', async () => {
  const posted: ReplyArgs[] = [];
  const postReply: PostReply = async (args) => {
    posted.push(args);
    return { ok: true };
  };
  const { client } = await connectedPair(postReply);
  try {
    const result = await client.callTool({
      name: 'design_canvas_reply',
      arguments: {
        annotation_id: 'ann-1',
        status: 'applied',
        message: 'Done.',
        pr_url: 'https://github.com/example/repo/pull/1',
      },
    });
    assert.equal(result.isError, undefined);
    assert.deepEqual(posted, [
      {
        annotationId: 'ann-1',
        status: 'applied',
        message: 'Done.',
        prUrl: 'https://github.com/example/repo/pull/1',
      },
    ]);
  } finally {
    await client.close();
  }
});

test('callTool with an unknown tool name is isError', async () => {
  const { client } = await connectedPair(async () => ({ ok: true }));
  try {
    const result = await client.callTool({ name: 'not_a_real_tool', arguments: {} });
    assert.equal(result.isError, true);
  } finally {
    await client.close();
  }
});

test('notifyAnnotation delivers one notifications/claude/channel notification with content and a 3-key meta', async () => {
  const compositePath = await makeCompositePath();
  const { client, channel } = await connectedPair(async () => ({ ok: true }));
  const received: Notification[] = [];
  client.fallbackNotificationHandler = async (notification) => {
    received.push(notification);
  };
  try {
    const annotation: ClaimedAnnotation = {
      meta: baseMeta(),
      compositePath,
      capturedAt: '2026-01-01T00:00:00.500Z',
    };
    await channel.notifyAnnotation(annotation);
    await new Promise((resolve) => setTimeout(resolve, 50));

    assert.equal(received.length, 1);
    const notification = received[0];
    assert.equal(notification?.method, 'notifications/claude/channel');
    const params = notification?.params as { content: string; meta: Record<string, string> };
    assert.equal(params.content, createInstructionText(annotation));
    assert.deepEqual(Object.keys(params.meta).sort(), ['annotation_id', 'device', 'source']);
    assert.equal(params.meta['source'], 'design-canvas');
    assert.equal(params.meta['annotation_id'], 'ann-1');
    assert.equal(params.meta['device'], 'iPad Pro');
  } finally {
    await client.close();
  }
});

test('notifyAnnotation delivers content equal to the template for a zoomed annotation too', async () => {
  const compositePath = await makeCompositePath();
  const { client, channel } = await connectedPair(async () => ({ ok: true }));
  const received: Notification[] = [];
  client.fallbackNotificationHandler = async (notification) => {
    received.push(notification);
  };
  try {
    const annotation: ClaimedAnnotation = {
      meta: baseMeta({
        id: 'ann-2',
        zoomRect: { x: 0.25, y: 0.1, w: 0.5, h: 0.4 },
        note: { text: 'Widen the sidebar.' },
      }),
      compositePath,
      capturedAt: '2026-01-01T00:00:00.500Z',
    };
    await channel.notifyAnnotation(annotation);
    await new Promise((resolve) => setTimeout(resolve, 50));

    assert.equal(received.length, 1);
    const params = received[0]?.params as { content: string; meta: Record<string, string> };
    assert.equal(params.content, createInstructionText(annotation));
    assert.match(params.content, /^Zoom region: x=0\.250 y=0\.100 w=0\.500 h=0\.400$/m);
  } finally {
    await client.close();
  }
});
