// Design Canvas server — wire types and constants.
// Ported from ai.cst.2 packages/shared/src/index.ts. Local to this package
// (no other package imports it); every former @design-canvas/shared import
// becomes a relative import of this file.

export const SERVER_PORT = 47100;
export const CHANNEL_NAME = 'design-canvas';
export const SCHEMA_VERSION = 2;
export const LEGACY_SCHEMA_VERSION = 1;
export const SERVICE_NAME = 'Design Canvas';
export const CLAIM_LEASE_MS = 30_000;

export const HTTP_PATHS = {
  health: '/v1/health',
  captures: '/v1/captures',
  annotations: '/v1/annotations',
  annotationStream: '/v1/annotations/stream',
} as const;

export interface Viewport {
  w: number;
  h: number;
}

export interface CaptureMeta {
  id: string;
  schemaVersion: number;
  createdAt: string;
  /** Human-readable label for the capture source (window title, or a URL from the legacy extension). */
  sourceLabel: string;
  viewport: Viewport;
}

export interface AnnotationNote {
  text: string | null;
  voiceFile: string | null;
}

export interface AnnotationMeta {
  id: string;
  schemaVersion: number;
  createdAt: string;
  servedAt: string | null;
  claimedAt: string | null;
  /** Human-readable label for the capture source (window title, or a URL from the legacy extension). */
  sourceLabel: string;
  viewport: Viewport;
  note: AnnotationNote;
  sourceCaptureId: string;
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
