import { readFile } from 'node:fs/promises';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CHANNEL_NAME } from '../shared.js';
import type { Logger } from '../log.js';
import type { AnnotationWithPath } from '../store/store.js';

export interface ChannelNotifier {
  readonly attached: boolean;
  /**
   * Establish the channel transport eagerly. For the MCP channel this completes
   * the stdio `initialize` handshake with the host (Claude Code) up front, so a
   * client peer is answered immediately rather than only when the first
   * annotation triggers a lazy connect. Idempotent.
   */
  connect(): Promise<void>;
  notifyAnnotation(annotation: AnnotationWithPath): Promise<void>;
}

export function createNullChannel(logger: Logger): ChannelNotifier {
  return {
    attached: false,
    async connect() {
      // No transport to establish.
    },
    async notifyAnnotation(annotation) {
      await logger.event('channel.skipped', {
        annotationId: annotation.meta.id,
        reason: 'channel_not_attached',
      });
    },
  };
}

export function createMcpChannel(logger: Logger): ChannelNotifier {
  const mcp = new Server(
    { name: CHANNEL_NAME, version: process.env['npm_package_version'] ?? '0.0.0' },
    {
      capabilities: {
        experimental: { 'claude/channel': {} },
      },
      instructions:
        'Design Canvas sends one-way iPad sketch annotations. Events arrive as <channel source="design-canvas" ...>. Inspect the referenced composite PNG, then apply the annotation to this project source code. No channel reply is expected.',
    },
  );
  const transport = new StdioServerTransport();
  let connectPromise: Promise<void> | null = null;

  mcp.oninitialized = () => {
    logger.event('channel.initialized', { channel: CHANNEL_NAME }).catch(() => {});
  };

  async function ensureConnected(): Promise<void> {
    connectPromise ??= mcp.connect(transport);
    await connectPromise;
  }

  return {
    attached: true,
    async connect() {
      await ensureConnected();
    },
    async notifyAnnotation(annotation) {
      await ensureConnected();
      const notification = await createNotification(annotation);
      await mcp.notification(notification);
      await logger.event('channel.notification.sent', {
        annotationId: annotation.meta.id,
        channel: CHANNEL_NAME,
      });
    },
  };
}

async function createNotification(
  annotation: AnnotationWithPath,
): Promise<{
  method: 'notifications/claude/channel';
  params: { content: string; meta: Record<string, string> };
}> {
  await readFile(annotation.compositePath);
  return {
    method: 'notifications/claude/channel',
    params: {
      content: createInstructionText(annotation),
      meta: {
        source: CHANNEL_NAME,
        annotation_id: annotation.meta.id,
      },
    },
  };
}

function createInstructionText(annotation: AnnotationWithPath): string {
  const meta = annotation.meta;
  const note = meta.note.text?.trim() ? meta.note.text.trim() : '(none)';
  return [
    'New annotation from iPad.',
    `Annotation ID: ${meta.id}`,
    `Captured at: ${meta.createdAt}`,
    `Sent at: ${meta.createdAt}`,
    `Composite PNG path: ${annotation.compositePath}`,
    `Note: ${note}`,
    '',
    'Inspect the composite PNG path to see the visual annotation.',
    'Apply this annotation to the source code.',
  ].join('\n');
}
