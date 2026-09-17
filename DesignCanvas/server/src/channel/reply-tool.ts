// design_canvas_reply tool logic — pure and unit-testable. No MCP SDK import
// here on purpose: this module is exercised directly by reply-tool.test.ts,
// and the SDK types/wiring stay isolated to index.ts.

import { REPLY_STATUSES, type ReplyStatus } from '../shared.js';

export const REPLY_TOOL = {
  name: 'design_canvas_reply',
  description:
    'Report the outcome of applying one Design Canvas annotation. Call this exactly once per ' +
    'annotation you were notified about, after you have applied (or attempted to apply) the ' +
    'requested change: status "applied" when the change was made, "failed" when it could not ' +
    'be, or "needs_input" when you need more information from the person who drew it. Include ' +
    'a short message describing what happened, and pr_url when the change went out as a pull request.',
  inputSchema: {
    type: 'object',
    required: ['annotation_id', 'status'],
    additionalProperties: false,
    properties: {
      annotation_id: { type: 'string', description: 'The annotation id from the notification.' },
      status: { type: 'string', enum: ['applied', 'failed', 'needs_input'] },
      message: { type: 'string', description: 'A short human-readable summary of the outcome.' },
      pr_url: { type: 'string', description: 'The pull request URL, when one was opened.' },
    },
  },
} as const;

export interface ReplyArgs {
  annotationId: string;
  status: ReplyStatus;
  message?: string;
  prUrl?: string;
}

const REPLY_STATUS_SET: readonly string[] = REPLY_STATUSES;

/**
 * Parses raw tool-call arguments from the model. Liberal in what it accepts:
 * unknown extra keys are ignored even though the published JSON schema says
 * `additionalProperties: false` (models send extras).
 */
export function parseReplyArgs(raw: unknown): ReplyArgs | { error: string } {
  if (typeof raw !== 'object' || raw === null) {
    return { error: 'Arguments must be an object with annotation_id and status.' };
  }
  const obj = raw as Record<string, unknown>;

  const annotationIdRaw = obj['annotation_id'];
  if (typeof annotationIdRaw !== 'string' || annotationIdRaw.trim().length === 0) {
    return { error: 'annotation_id must be a non-empty string.' };
  }
  const annotationId = annotationIdRaw.trim();

  const statusRaw = obj['status'];
  if (typeof statusRaw !== 'string' || !REPLY_STATUS_SET.includes(statusRaw)) {
    return { error: `status must be one of: ${REPLY_STATUSES.join(', ')}.` };
  }
  const status = statusRaw as ReplyStatus;

  const messageRaw = obj['message'];
  if (messageRaw !== undefined && typeof messageRaw !== 'string') {
    return { error: 'message must be a string.' };
  }

  const prUrlRaw = obj['pr_url'];
  if (prUrlRaw !== undefined && typeof prUrlRaw !== 'string') {
    return { error: 'pr_url must be a string.' };
  }

  const result: ReplyArgs = { annotationId, status };
  if (typeof messageRaw === 'string' && messageRaw.length > 0) {
    result.message = messageRaw;
  }
  if (typeof prUrlRaw === 'string' && prUrlRaw.length > 0) {
    result.prUrl = prUrlRaw;
  }
  return result;
}

export type PostReply = (
  args: ReplyArgs,
) => Promise<{ ok: true } | { ok: false; status: number; code: string }>;

export interface ReplyToolResult {
  content: [{ type: 'text'; text: string }];
  isError?: true;
}

export async function handleReplyCall(raw: unknown, post: PostReply): Promise<ReplyToolResult> {
  const parsed = parseReplyArgs(raw);
  if ('error' in parsed) {
    return { content: [{ type: 'text', text: parsed.error }], isError: true };
  }

  const result = await post(parsed);
  if (result.ok) {
    return { content: [{ type: 'text', text: 'Reply recorded.' }] };
  }
  if (result.status === 409) {
    return {
      content: [{ type: 'text', text: 'A reply was already recorded for this annotation.' }],
      isError: true,
    };
  }
  if (result.status === 404) {
    return { content: [{ type: 'text', text: 'Unknown annotation id.' }], isError: true };
  }
  return {
    content: [
      {
        type: 'text',
        text: `Could not reach the Design Canvas daemon (${result.code}).`,
      },
    ],
    isError: true,
  };
}
