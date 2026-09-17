import { randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { copyFile, mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  type AnnotationDevice,
  type AnnotationMeta,
  type AnnotationNote,
  type AnnotationReply,
  CAPTURE_TTL_MS,
  type CaptureMeta,
  CLAIM_LEASE_MS,
  type ReplyStatus,
  SCHEMA_VERSION,
  type Viewport,
  type ZoomRect,
} from '../shared.js';
import type { Logger } from '../log.js';
import { createStorePaths, type StorePaths } from './paths.js';
import { uuidv7 } from './uuidv7.js';

export interface CreateCaptureInput {
  screenshot: Buffer;
  viewport: Viewport;
  createdAt?: string;
}

export interface CreateAnnotationInput {
  composite: Buffer;
  sketch: Buffer;
  sourceCaptureId: string;
  viewport: Viewport;
  zoomRect: ZoomRect | null;
  device: AnnotationDevice;
  note?: Partial<AnnotationNote>;
  createdAt?: string;
}

export interface CaptureWithPath {
  meta: CaptureMeta;
  screenshotPath: string;
}

export interface AnnotationWithPath {
  meta: AnnotationMeta;
  compositePath: string;
  sketchPath: string | null;
}

export interface ClaimedAnnotation extends AnnotationWithPath {
  /** The source capture's createdAt, or the annotation's own createdAt when the capture is gone. */
  capturedAt: string;
}

export interface SetReplyInput {
  status: ReplyStatus;
  message: string | null;
  prUrl: string | null;
}

/** createAnnotation was given a sourceCaptureId with no matching capture on disk. */
export class UnknownCaptureError extends Error {
  constructor(readonly sourceCaptureId: string) {
    super(`Unknown capture: ${sourceCaptureId}`);
  }
}

/**
 * The only shape of id this store will join into a path: the alphabet its own
 * `uuidv7()` and `createSortableId()` produce, and nothing that can name a parent
 * directory or a second path segment.
 */
export const STORE_ID_PATTERN = /^[A-Za-z0-9-]+$/;

/** An id from a request that must never be joined into a store path (M3). */
export class InvalidStoreIdError extends Error {
  constructor(readonly id: string) {
    super(`Invalid store id: ${id}`);
  }
}

/**
 * Guards every id that becomes part of a filesystem path. Ids arrive from route
 * paths *and* from request bodies (`sourceCaptureId`), and `../annotations/<id>`
 * in a body made the store read an annotation's directory as a capture and copy a
 * file out of it. One check here covers every caller, whatever the route table does.
 */
function requireStoreId(id: string): string {
  if (!STORE_ID_PATTERN.test(id)) {
    throw new InvalidStoreIdError(id);
  }
  return id;
}

export class DesignCanvasStore {
  readonly paths: StorePaths;

  private readonly locks = new Map<string, Promise<unknown>>();

  private async withLock<T>(id: string, fn: () => Promise<T>): Promise<T> {
    const prior = this.locks.get(id) ?? Promise.resolve();
    const run = prior.then(fn, fn); // run after prior settles (either way)
    const chained = run.catch(() => {}); // wrap ONCE so the next caller can await it
    this.locks.set(id, chained);
    try {
      return await run;
    } finally {
      if (this.locks.get(id) === chained) this.locks.delete(id); // only delete if still the tail
    }
  }

  constructor(
    private readonly logger: Logger,
    paths = createStorePaths(),
  ) {
    this.paths = paths;
  }

  async ensure(): Promise<void> {
    await mkdir(this.paths.captures, { recursive: true });
    await mkdir(this.paths.annotations, { recursive: true });
  }

  async createCapture(input: CreateCaptureInput): Promise<CaptureMeta> {
    await this.ensure();
    const id = createSortableId();
    const createdAt = input.createdAt ?? new Date().toISOString();
    const dir = join(this.paths.captures, id);
    await mkdir(dir, { recursive: true });
    const meta: CaptureMeta = {
      id,
      schemaVersion: SCHEMA_VERSION,
      createdAt,
      viewport: input.viewport,
    };
    await writeFile(join(dir, 'screenshot.png'), input.screenshot);
    await writeJson(join(dir, 'meta.json'), meta);
    await this.logger.event('capture.created', { captureId: id });
    return meta;
  }

  async latestCapture(): Promise<CaptureWithPath | null> {
    await this.ensure();
    const captures = await this.listCaptures();
    const latest = captures.at(-1);
    return latest ?? null;
  }

  async getCapture(id: string): Promise<CaptureWithPath | null> {
    requireStoreId(id);
    await this.ensure();
    return readCapture(this.paths.captures, id);
  }

  /** Throws UnknownCaptureError (and writes nothing) if sourceCaptureId has no capture. */
  async createAnnotation(input: CreateAnnotationInput): Promise<AnnotationMeta> {
    requireStoreId(input.sourceCaptureId);
    await this.ensure();
    const capture = await this.getCapture(input.sourceCaptureId);
    if (!capture) {
      throw new UnknownCaptureError(input.sourceCaptureId);
    }
    const id = uuidv7();
    const createdAt = input.createdAt ?? new Date().toISOString();
    const dir = join(this.paths.annotations, id);
    await mkdir(dir, { recursive: true });
    const note: AnnotationNote = {
      text: input.note?.text ?? null,
    };
    const meta: AnnotationMeta = {
      id,
      schemaVersion: SCHEMA_VERSION,
      createdAt,
      // Recorded here because the capture is deleted below: this is the only
      // place the frame's own time survives (I5).
      capturedAt: capture.meta.createdAt,
      claimedAt: null,
      servedAt: null,
      viewport: input.viewport,
      zoomRect: input.zoomRect,
      note,
      sourceCaptureId: input.sourceCaptureId,
      device: input.device,
      reply: null,
    };
    await writeFile(join(dir, 'composite.png'), input.composite);
    await writeFile(join(dir, 'sketch.png'), input.sketch);
    await copyFile(capture.screenshotPath, join(dir, 'screenshot.png'));
    await writeJson(join(dir, 'meta.json'), meta);
    // The capture has been consumed: its screenshot is now this annotation's own
    // copy, and nothing else will ever read it. Deleting it last means a failure
    // above leaves the capture intact for a retry (I5).
    await rm(join(this.paths.captures, input.sourceCaptureId), { recursive: true, force: true });
    await this.logger.event('annotation.created', {
      annotationId: id,
      sourceCaptureId: input.sourceCaptureId,
      deviceId: input.device.id,
    });
    return meta;
  }

  /**
   * Deletes captures older than `ttlMs` — the ones a Draw Mode entry posted and no
   * sketch ever claimed. A directory without a readable `meta.json` is left alone:
   * it may be a capture mid-write, and guessing its age is not worth deleting
   * someone's frame over.
   */
  async pruneCaptures(ttlMs = CAPTURE_TTL_MS, now = new Date()): Promise<number> {
    await this.ensure();
    const ids = await safeIds(this.paths.captures);
    let removed = 0;
    for (const id of ids) {
      const capture = await readCapture(this.paths.captures, id);
      const createdAt = capture ? Date.parse(capture.meta.createdAt) : NaN;
      if (!Number.isFinite(createdAt)) continue;
      if (now.getTime() - createdAt <= ttlMs) continue;
      await rm(join(this.paths.captures, id), { recursive: true, force: true });
      await this.logger.event('capture.pruned', { captureId: id });
      removed += 1;
    }
    return removed;
  }

  async markAnnotationServed(
    id: string,
    servedAt = new Date().toISOString(),
  ): Promise<AnnotationMeta> {
    requireStoreId(id);
    return this.withLock(id, async () => {
      const annotation = await this.getAnnotation(id);
      if (!annotation) {
        throw new Error(`Annotation not found: ${id}`);
      }
      const meta = { ...annotation.meta, servedAt };
      await writeJson(join(this.paths.annotations, id, 'meta.json'), meta);
      await this.logger.event('annotation.served', { annotationId: id, servedAt });
      return meta;
    });
  }

  /**
   * Refuses (returns null) a second reply for the same annotation; stores the
   * full message untruncated. Independent of claim/served state: a reply may
   * arrive before or after the annotation is marked served.
   */
  async setReply(
    id: string,
    reply: SetReplyInput,
    at = new Date().toISOString(),
  ): Promise<AnnotationMeta | null> {
    requireStoreId(id);
    return this.withLock(id, async () => {
      const annotation = await this.getAnnotation(id);
      if (!annotation) {
        throw new Error(`Annotation not found: ${id}`);
      }
      if (annotation.meta.reply !== null) return null; // already replied
      const recorded: AnnotationReply = { ...reply, at };
      const meta = { ...annotation.meta, reply: recorded };
      await writeJson(join(this.paths.annotations, id, 'meta.json'), meta);
      await this.logger.event('annotation.replied', { annotationId: id, status: reply.status });
      return meta;
    });
  }

  async claimAnnotation(
    id: string,
    leaseMs = CLAIM_LEASE_MS,
  ): Promise<ClaimedAnnotation | null> {
    requireStoreId(id);
    return this.withLock(id, async () => {
      const annotation = await this.getAnnotation(id);
      if (!annotation) return null;
      const { servedAt, claimedAt } = annotation.meta;
      if (servedAt !== null) return null; // already served
      if (claimedAt !== null && Date.now() - Date.parse(claimedAt) < leaseMs) return null; // live lease
      const meta = { ...annotation.meta, claimedAt: new Date().toISOString() };
      await writeJson(join(this.paths.annotations, id, 'meta.json'), meta);
      await this.logger.event('annotation.claimed', { annotationId: id });
      // `capturedAt` is recorded on the annotation as it is created; the capture
      // lookup is only for records written before that field existed, and the
      // annotation's own createdAt is the last resort.
      const capture = meta.capturedAt ? null : await this.getCapture(meta.sourceCaptureId);
      const capturedAt = meta.capturedAt ?? capture?.meta.createdAt ?? meta.createdAt;
      return { ...annotation, meta, capturedAt };
    });
  }

  async reconcileStaleClaims(leaseMs = CLAIM_LEASE_MS): Promise<number> {
    await this.ensure();
    const ids = await safeIds(this.paths.annotations);
    // Unlocked scan to find candidates; the authoritative re-check happens under the lock.
    const candidates: string[] = [];
    for (const id of ids) {
      const annotation = await readAnnotation(this.paths.annotations, id);
      if (!annotation) continue;
      const { servedAt, claimedAt } = annotation.meta;
      if (servedAt !== null || claimedAt === null) continue;
      if (Date.now() - Date.parse(claimedAt) < leaseMs) continue;
      candidates.push(id);
    }
    let reset = 0;
    for (const id of candidates) {
      const didReset = await this.withLock(id, async () => {
        const annotation = await this.getAnnotation(id);
        if (!annotation) return false;
        const { servedAt, claimedAt } = annotation.meta;
        // Re-check staleness now that we hold the lock; a claim may have been
        // granted between the scan and acquiring the lock.
        if (servedAt !== null || claimedAt === null) return false;
        if (Date.now() - Date.parse(claimedAt) < leaseMs) return false;
        const meta = { ...annotation.meta, claimedAt: null };
        await writeJson(join(this.paths.annotations, id, 'meta.json'), meta);
        await this.logger.event('annotation.reconciled', { annotationId: id });
        return true;
      });
      if (didReset) reset += 1;
    }
    return reset;
  }

  async getAnnotation(id: string): Promise<AnnotationWithPath | null> {
    requireStoreId(id);
    await this.ensure();
    return readAnnotation(this.paths.annotations, id);
  }

  async listAnnotations(): Promise<AnnotationMeta[]> {
    await this.ensure();
    const ids = await safeIds(this.paths.annotations);
    const annotations = await Promise.all(
      ids.map((id) => readAnnotation(this.paths.annotations, id)),
    );
    return annotations
      .filter((annotation): annotation is AnnotationWithPath => annotation !== null)
      .map((annotation) => annotation.meta)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async pendingAnnotations(leaseMs = CLAIM_LEASE_MS): Promise<AnnotationWithPath[]> {
    await this.ensure();
    const ids = await safeIds(this.paths.annotations);
    const annotations = await Promise.all(
      ids.map((id) => readAnnotation(this.paths.annotations, id)),
    );
    return annotations
      .filter((annotation): annotation is AnnotationWithPath => {
        if (annotation === null || annotation.meta.servedAt !== null) return false;
        const { claimedAt } = annotation.meta;
        return claimedAt === null || Date.now() - Date.parse(claimedAt) >= leaseMs;
      })
      .sort((a, b) => a.meta.createdAt.localeCompare(b.meta.createdAt));
  }

  async deleteAnnotation(id: string): Promise<boolean> {
    requireStoreId(id);
    const annotation = await this.getAnnotation(id);
    if (!annotation) {
      return false;
    }
    await rm(join(this.paths.annotations, id), { recursive: true, force: true });
    await this.logger.event('annotation.deleted', { annotationId: id });
    return true;
  }

  createCompositeStream(annotation: AnnotationWithPath) {
    return createReadStream(annotation.compositePath);
  }

  private async listCaptures(): Promise<CaptureWithPath[]> {
    const ids = await safeIds(this.paths.captures);
    const captures = await Promise.all(ids.map((id) => readCapture(this.paths.captures, id)));
    return captures
      .filter((capture): capture is CaptureWithPath => capture !== null)
      .sort((a, b) => a.meta.createdAt.localeCompare(b.meta.createdAt));
  }
}

async function safeIds(root: string): Promise<string[]> {
  try {
    const entries = await readdir(root, { withFileTypes: true });
    return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name);
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

async function readCapture(root: string, id: string): Promise<CaptureWithPath | null> {
  try {
    const meta = await readJson<CaptureMeta>(join(root, id, 'meta.json'));
    return {
      meta,
      screenshotPath: join(root, id, 'screenshot.png'),
    };
  } catch (error) {
    if (isMissingStoreEntry(error)) {
      return null;
    }
    throw error;
  }
}

/** Raw shape as it may exist on disk: a v2 record predates zoomRect/device/reply. */
type RawAnnotationMeta = Omit<AnnotationMeta, 'zoomRect' | 'device' | 'reply' | 'claimedAt'> & {
  claimedAt?: string | null;
  zoomRect?: ZoomRect | null;
  device?: AnnotationDevice;
  reply?: AnnotationReply | null;
  /** v2 and earlier; ignored on read. */
  sourceLabel?: string;
};

async function readAnnotation(root: string, id: string): Promise<AnnotationWithPath | null> {
  try {
    const raw = await readJson<RawAnnotationMeta>(join(root, id, 'meta.json'));
    const meta: AnnotationMeta = {
      id: raw.id,
      schemaVersion: raw.schemaVersion,
      createdAt: raw.createdAt,
      // Absent on records written before the field existed; the claim path falls
      // back for those.
      ...(raw.capturedAt ? { capturedAt: raw.capturedAt } : {}),
      claimedAt: raw.claimedAt ?? null,
      servedAt: raw.servedAt,
      viewport: raw.viewport,
      zoomRect: raw.zoomRect ?? null,
      note: raw.note,
      sourceCaptureId: raw.sourceCaptureId,
      device: raw.device ?? { id: '', name: '' },
      reply: raw.reply ?? null,
    };
    return {
      meta,
      compositePath: join(root, id, 'composite.png'),
      sketchPath: join(root, id, 'sketch.png'),
    };
  } catch (error) {
    if (isMissingStoreEntry(error)) {
      return null;
    }
    throw error;
  }
}

function isMissingStoreEntry(error: unknown): boolean {
  return (
    error instanceof Error &&
    'code' in error &&
    (error.code === 'ENOENT' || error.code === 'ENOTDIR')
  );
}

async function readJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, 'utf8')) as T;
}

async function writeJson(path: string, value: unknown): Promise<void> {
  const tmp = `${path}.${randomBytes(6).toString('hex')}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(tmp, path);
}

function createSortableId(): string {
  return `${Date.now().toString(36)}-${randomBytes(8).toString('hex')}`;
}
