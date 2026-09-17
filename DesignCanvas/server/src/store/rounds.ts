import { type AnnotationMeta, REPLY_MESSAGE_MAX_BYTES, type Round, type RoundStatus } from '../shared.js';

/** queued -> sent (served) -> one of applied/failed/needs_input, once a reply lands. */
export function roundStatus(meta: AnnotationMeta): RoundStatus {
  return meta.reply?.status ?? (meta.servedAt ? 'sent' : 'queued');
}

/**
 * Truncates `text` to at most `maxBytes` UTF-8 bytes without ever splitting a
 * code point. Used to keep a reply message under the wire limit wherever a
 * Round is emitted; the full message stays in the store untouched.
 */
export function truncateUtf8(text: string, maxBytes: number): string {
  const buffer = Buffer.from(text, 'utf8');
  if (buffer.byteLength <= maxBytes) return text;
  let end = maxBytes;
  // A UTF-8 continuation byte matches 0b10xxxxxx (0x80-0xBF). Back off until
  // the byte just past the cut is not a continuation byte, i.e. the cut lands
  // on a code point boundary.
  while (end > 0 && (buffer[end]! & 0xc0) === 0x80) {
    end -= 1;
  }
  return buffer.subarray(0, end).toString('utf8');
}

/** Projects one annotation's lifecycle into a Round for /v1/rounds and the rounds stream. */
export function toRound(meta: AnnotationMeta): Round {
  const round: Round = {
    annotationId: meta.id,
    createdAt: meta.createdAt,
    status: roundStatus(meta),
  };
  if (meta.note.text) {
    round.note = meta.note.text;
  }
  if (meta.reply?.message) {
    round.message = truncateUtf8(meta.reply.message, REPLY_MESSAGE_MAX_BYTES);
  }
  if (meta.reply?.prUrl) {
    round.prUrl = meta.reply.prUrl;
  }
  return round;
}
