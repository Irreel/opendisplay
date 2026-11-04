import { readFile } from 'node:fs/promises';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type ServerResult,
} from '@modelcontextprotocol/sdk/types.js';
import { CHANNEL_NAME, SERVER_PORT, type AnnotationMeta } from '../shared.js';
import type { Logger } from '../log.js';
import { REPLY_TOOL, handleReplyCall, parseReplyArgs, type PostReply } from './reply-tool.js';

/** What the daemon hands back from a successful claim (Task 6). */
export interface ClaimedAnnotation {
  meta: AnnotationMeta;
  compositePath: string;
  capturedAt: string;
}

export interface ChannelNotifier {
  readonly attached: boolean;
  /**
   * Establish the channel transport eagerly. For the MCP channel this completes
   * the stdio `initialize` handshake with the host (Claude Code) up front, so a
   * client peer is answered immediately rather than only when the first
   * annotation triggers a lazy connect. Idempotent.
   */
  connect(): Promise<void>;
  notifyAnnotation(annotation: ClaimedAnnotation): Promise<void>;
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

export interface CreateMcpChannelOptions {
  /** Overrides the stdio transport — used by tests (e.g. an InMemoryTransport half). */
  transport?: Transport;
  /** Overrides how a reply is posted to the daemon — used by tests. */
  postReply?: PostReply;
  /** Overrides the daemon base URL used by the default postReply. */
  baseUrl?: string;
}

export function createMcpChannel(
  logger: Logger,
  options: CreateMcpChannelOptions = {},
): ChannelNotifier {
  const mcp = new Server(
    { name: CHANNEL_NAME, version: process.env['npm_package_version'] ?? '0.0.0' },
    {
      capabilities: {
        experimental: { 'claude/channel': {} },
        tools: {},
      },
      instructions: [
        'Design Canvas pushes iPad sketch annotations into this session.',
        'Events arrive as <channel source="design-canvas" ...> notifications.',
        "Read the composite PNG at the given path, then apply the change to this project's source.",
        'An event that says "blank canvas" is a freehand sketch on a blank page rather than a',
        'marked-up screenshot of the running app: read it together with its note.',
        'Call design_canvas_reply exactly once per annotation, with status applied, failed, or',
        'needs_input, a short message, and pr_url when a pull request was opened.',
      ].join(' '),
    },
  );
  const transport = options.transport ?? new StdioServerTransport();
  const postReply = options.postReply ?? createDefaultPostReply(options.baseUrl);
  let connectPromise: Promise<void> | null = null;

  mcp.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [REPLY_TOOL] }));

  mcp.setRequestHandler(CallToolRequestSchema, async (request): Promise<ServerResult> => {
    const { name, arguments: args } = request.params;
    if (name !== REPLY_TOOL.name) {
      return {
        content: [{ type: 'text', text: `Unknown tool: ${name}` }],
        isError: true,
      } as ServerResult;
    }
    const parsed = parseReplyArgs(args);
    const annotationId = 'error' in parsed ? undefined : parsed.annotationId;
    await logger.event('channel.reply.received', { annotationId });
    const result = await handleReplyCall(args, postReply);
    await logger.event(result.isError ? 'channel.reply.failed' : 'channel.reply.posted', {
      annotationId,
      ...(result.isError ? { reason: result.content[0].text } : {}),
    });
    return result as ServerResult;
  });

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

/** Posts the full reply message to the daemon's reply endpoint (no truncation — ruling 2). */
function createDefaultPostReply(baseUrl?: string): PostReply {
  const port = process.env['SERVER_PORT'] ?? SERVER_PORT;
  const base = baseUrl ?? `http://127.0.0.1:${port}`;
  return async (args) => {
    let response: Response;
    try {
      response = await fetch(`${base}/v1/annotations/${encodeURIComponent(args.annotationId)}/reply`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          status: args.status,
          ...(args.message !== undefined ? { message: args.message } : {}),
          ...(args.prUrl !== undefined ? { prUrl: args.prUrl } : {}),
        }),
      });
    } catch {
      return { ok: false, status: 0, code: 'network_error' };
    }
    if (response.ok) {
      return { ok: true };
    }
    let code = 'unknown_error';
    try {
      const body = (await response.json()) as { error?: unknown };
      if (typeof body.error === 'string') code = body.error;
    } catch {
      // Body wasn't JSON — keep the generic code.
    }
    return { ok: false, status: response.status, code };
  };
}

async function createNotification(
  annotation: ClaimedAnnotation,
): Promise<{
  method: 'notifications/claude/channel';
  params: { content: string; meta: { source: string; annotation_id: string; device: string } };
}> {
  await readFile(annotation.compositePath);
  return {
    method: 'notifications/claude/channel',
    params: {
      content: createInstructionText(annotation),
      meta: {
        source: CHANNEL_NAME,
        annotation_id: annotation.meta.id,
        device: annotation.meta.device.name,
      },
    },
  };
}

export function createInstructionText(annotation: ClaimedAnnotation): string {
  const meta = annotation.meta;
  const device = meta.device.name.length > 0 ? meta.device.name : 'unknown iPad';
  const note = meta.note.text?.trim() ? meta.note.text.trim() : '(none)';
  // Drawn on the iPad's blank canvas: there is no frame, so no capture time and no zoom
  // region, and the model must not read the white page as the app's own screen.
  if (meta.base === 'blank') {
    return [
      'New sketch from iPad (blank canvas).',
      `Annotation ID: ${meta.id}`,
      `Device: ${device}`,
      `Sent at: ${meta.createdAt}`,
      `Composite PNG path: ${annotation.compositePath}`,
      `Note: ${note}`,
      '',
      'This is a freehand sketch drawn on a blank page, not a screenshot of the running app.',
      'Inspect the composite PNG path to see it, read it together with the note, and act on it in this project, then call design_canvas_reply with the outcome.',
    ].join('\n');
  }
  const zoom =
    meta.zoomRect === null
      ? 'full frame'
      : `x=${meta.zoomRect.x.toFixed(3)} y=${meta.zoomRect.y.toFixed(3)} w=${meta.zoomRect.w.toFixed(3)} h=${meta.zoomRect.h.toFixed(3)}`;
  return [
    'New annotation from iPad.',
    `Annotation ID: ${meta.id}`,
    `Device: ${device}`,
    `Captured at: ${annotation.capturedAt}`,
    `Sent at: ${meta.createdAt}`,
    `Composite PNG path: ${annotation.compositePath}`,
    `Zoom region: ${zoom}`,
    `Note: ${note}`,
    '',
    'Inspect the composite PNG path to see the visual annotation.',
    'Apply this annotation to the source code, then call design_canvas_reply with the outcome.',
  ].join('\n');
}
