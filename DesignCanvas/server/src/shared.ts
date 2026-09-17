// Design Canvas server — wire types and constants.
// Ported from ai.cst.2 packages/shared/src/index.ts. Local to this package
// (no other package imports it); every former @design-canvas/shared import
// becomes a relative import of this file.

export const SERVER_PORT = 47100;
export const CHANNEL_NAME = 'design-canvas';
export const SCHEMA_VERSION = 3;
export const SERVICE_NAME = 'Design Canvas';
export const CLAIM_LEASE_MS = 30_000;
/**
 * How long a capture that was never turned into an annotation is kept. Entering Draw
 * Mode posts a full-resolution frame whether the sketch is ever sent or not, so
 * without this the capture directory only grew (I5). A consumed capture is deleted
 * at once by `createAnnotation`; this is the sweep for the rest.
 */
export const CAPTURE_TTL_MS = 6 * 60 * 60 * 1000;
/** How often the daemon runs that sweep (also once at startup). */
export const CAPTURE_SWEEP_MS = 60 * 60 * 1000;

export const REPLY_STATUSES = ['applied', 'failed', 'needs_input'] as const;
export type ReplyStatus = (typeof REPLY_STATUSES)[number];
export const REPLY_MESSAGE_MAX_BYTES = 2048;
export const ROUNDS_LIMIT = 20;
export type RoundStatus = 'queued' | 'sent' | 'applied' | 'failed' | 'needs_input';

export const HTTP_PATHS = {
  health: '/v1/health',
  captures: '/v1/captures',
  annotations: '/v1/annotations',
  annotationStream: '/v1/annotations/stream',
  rounds: '/v1/rounds',
  roundsStream: '/v1/rounds/stream',
} as const;

export interface Viewport {
  w: number;
  h: number;
  scale?: number;
}

export interface ZoomRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface CaptureMeta {
  id: string;
  schemaVersion: number;
  createdAt: string;
  viewport: Viewport;
}

export interface AnnotationNote {
  text: string | null;
}

export interface AnnotationDevice {
  id: string;
  name: string;
}

export interface AnnotationReply {
  status: ReplyStatus;
  message: string | null;
  prUrl: string | null;
  at: string;
}

export interface AnnotationMeta {
  id: string;
  schemaVersion: number;
  createdAt: string;
  /**
   * When the frame under this sketch was captured, copied from the source capture as
   * the annotation is created. Additive on schema 3 (absent on records written before
   * it existed): the capture directory is deleted the moment it is consumed (I5), so
   * this is the only place that time survives.
   */
  capturedAt?: string;
  claimedAt: string | null;
  servedAt: string | null;
  viewport: Viewport;
  zoomRect: ZoomRect | null;
  note: AnnotationNote;
  sourceCaptureId: string;
  device: AnnotationDevice;
  reply: AnnotationReply | null;
}

export interface HealthResponse {
  status: 'ok';
  version: string;
  channelAttached: boolean;
  /** Daemon process PID. */
  pid?: number;
  /** Random ID generated once at daemon startup. */
  instanceId?: string;
  /** ISO 8601 daemon start time. */
  startedAt?: string;
  /** Absolute path of the running server entry (process.argv[1]). */
  serverEntry?: string;
  /** The port the daemon bound. */
  port?: number;
  /** Current SSE subscriber count. */
  channelCount?: number;
  /** ISO time the oldest current subscriber attached; null/absent when none. */
  channelAttachedAt?: string | null;
}

export interface AnnotationUploadResponse {
  annotationId: string;
  /**
   * True if a channel process was subscribed at emit time — i.e. someone is listening.
   * NOT a delivery/claim guarantee: delivery is at-least-once and a subscriber may drop
   * after this returns; the daemon's lease sweep recovers such cases.
   */
  dispatched: boolean;
}

/** A projection of one annotation's lifecycle for the iPad's rounds list/snapshot. */
export interface Round {
  annotationId: string;
  createdAt: string;
  status: RoundStatus;
  message?: string;
  prUrl?: string;
  note?: string;
}

/** A `Round` tagged with the device it belongs to, for the rounds SSE stream. */
export interface RoundEvent extends Round {
  deviceId: string;
}
