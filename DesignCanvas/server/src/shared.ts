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

/**
 * A session (a Claude Code process with the Design Canvas mod loaded) polls once a
 * second. One that has been silent this long is gone: a closed terminal, a kill.
 */
export const SESSION_STALE_MS = 15_000;
/**
 * After the daemon starts, sessions that were connected to the previous daemon are
 * still re-registering (each on its next 1 s tick). Nothing is failed and the
 * default target stays open to revision until this has passed.
 */
export const SESSION_SETTLE_MS = 5_000;
/** How often the daemon looks for sessions that stopped polling. */
export const SESSION_SWEEP_MS = 2_000;

export const REPLY_STATUSES = ['applied', 'failed', 'needs_input'] as const;
export type ReplyStatus = (typeof REPLY_STATUSES)[number];
export const REPLY_MESSAGE_MAX_BYTES = 2048;
/** Longest `prUrl` accepted, in characters. */
export const PR_URL_MAX_LENGTH = 2048;

/**
 * Whether a reply's `prUrl` may be stored and relayed. The model fills this in from
 * whatever it read while working, and it ends up on the iPad as a tappable link — so
 * only http(s) with a host, and nothing longer than `PR_URL_MAX_LENGTH` (M4). The
 * daemon and the channel's reply tool both use this, so the model gets a clear tool
 * error rather than a 400 it has to interpret.
 */
export function isAllowedPrUrl(value: string): boolean {
  if (value.length > PR_URL_MAX_LENGTH) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return (url.protocol === 'http:' || url.protocol === 'https:') && url.hostname.length > 0;
}
/**
 * Why a reply was written by the mod rather than by Claude: the round's turn ended
 * with no outcome after one reminder, the session ended first, or the user stopped
 * the turn. Absent on Claude's own reply.
 */
export const REPLY_REASONS = ['no_reply', 'session_ended', 'interrupted'] as const;
export type ReplyReason = (typeof REPLY_REASONS)[number];
export const ROUNDS_LIMIT = 20;
export type RoundStatus = 'queued' | 'sent' | 'applied' | 'failed' | 'needs_input';

export const HTTP_PATHS = {
  health: '/v1/health',
  captures: '/v1/captures',
  annotations: '/v1/annotations',
  annotationStream: '/v1/annotations/stream',
  rounds: '/v1/rounds',
  roundsStream: '/v1/rounds/stream',
  sessions: '/v1/sessions',
  sessionsStream: '/v1/sessions/stream',
  sessionsTarget: '/v1/sessions/target',
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
  reason?: ReplyReason;
}

/** The session a round is bound to: it is delivered there and nowhere else. */
export interface AnnotationSession {
  instance: string;
  sessionId: string;
  folder: string;
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
  /**
   * What the sketch was drawn on. Absent for a round on the mirror surface (a frozen
   * frame of the Mac's screen), which is every record written before the field existed.
   * `blank` for a freehand sketch on the iPad's blank canvas: its source capture is a
   * white page, and no screen content is part of the round.
   */
  base?: AnnotationBase;
  /** Absent until the round is bound: at upload when a target exists, else at first claim. */
  session?: AnnotationSession;
  /** When the mod sent its one reminder for a turn that ended with no outcome. */
  remindedAt?: string;
}

export type AnnotationBase = 'blank';

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
  /** Claude Code sessions connected through the mod. */
  sessionCount?: number;
}

export const SESSION_STATES = ['idle', 'busy', 'waiting'] as const;
/** `waiting`: Claude Code has a permission dialog open at the Mac. */
export type SessionState = (typeof SESSION_STATES)[number];

/** One connected Claude Code session, as the Mac app and the iPad list it. */
export interface SessionInfo {
  /** The mod's own id for this process. Stable across `/clear`, unlike `sessionId`. */
  instance: string;
  sessionId: string;
  cwd: string;
  /** Last path component of the repo root, or of `cwd` outside a repo. */
  folder: string;
  branch?: string;
  title?: string;
  startedAt: string;
  lastReplyAt?: string;
  state: SessionState;
  modVersion?: string;
  /** The nonce the Mac app put in the environment of a session it launched. */
  launch?: string;
}

export interface SessionsSnapshot {
  sessions: SessionInfo[];
  /** Null with several sessions means the user has to pick. */
  target: string | null;
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
