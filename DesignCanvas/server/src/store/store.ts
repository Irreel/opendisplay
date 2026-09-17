import { randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  type AnnotationMeta,
  type AnnotationNote,
  type CaptureMeta,
  CLAIM_LEASE_MS,
  LEGACY_SCHEMA_VERSION,
  SCHEMA_VERSION,
  type Viewport,
} from '../shared.js';
import type { Logger } from '../log.js';
import { createStorePaths, type StorePaths } from './paths.js';
import { uuidv7 } from './uuidv7.js';

export interface CreateCaptureInput {
  screenshot: Buffer;
  sourceLabel: string;
  viewport: Viewport;
  createdAt?: string;
}

export interface CreateAnnotationInput {
  composite: Buffer;
  sketch?: Buffer | null;
  noteFile?: Buffer | null;
  sourceCaptureId: string;
  sourceLabel: string;
  viewport: Viewport;
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
      sourceLabel: input.sourceLabel,
      viewport: input.viewport,
    };
    await writeFile(join(dir, 'screenshot.png'), input.screenshot);
    await writeJson(join(dir, 'meta.json'), meta);
    await this.logger.event('capture.created', { captureId: id, sourceLabel: meta.sourceLabel });
    return meta;
  }

  async latestCapture(): Promise<CaptureWithPath | null> {
    await this.ensure();
    const captures = await this.listCaptures();
    const latest = captures.at(-1);
    return latest ?? null;
  }

  async getCapture(id: string): Promise<CaptureWithPath | null> {
    await this.ensure();
    return readCapture(this.paths.captures, id);
  }

  async createAnnotation(input: CreateAnnotationInput): Promise<AnnotationMeta> {
    await this.ensure();
    const id = uuidv7();
    const createdAt = input.createdAt ?? new Date().toISOString();
    const dir = join(this.paths.annotations, id);
    await mkdir(dir, { recursive: true });
    const note: AnnotationNote = {
      text: input.note?.text ?? null,
      voiceFile: input.noteFile ? 'note.m4a' : (input.note?.voiceFile ?? null),
    };
    const meta: AnnotationMeta = {
      id,
      schemaVersion: SCHEMA_VERSION,
      createdAt,
      servedAt: null,
      claimedAt: null,
      sourceLabel: input.sourceLabel,
      viewport: input.viewport,
      note,
      sourceCaptureId: input.sourceCaptureId,
    };
    await writeFile(join(dir, 'composite.png'), input.composite);
    if (input.sketch) {
      await writeFile(join(dir, 'sketch.png'), input.sketch);
    }
    if (input.noteFile) {
      await writeFile(join(dir, 'note.m4a'), input.noteFile);
    }
    await writeJson(join(dir, 'meta.json'), meta);
    await this.logger.event('annotation.created', {
      annotationId: id,
      sourceCaptureId: input.sourceCaptureId,
      sourceLabel: meta.sourceLabel,
    });
    return meta;
  }

  async markAnnotationServed(
    id: string,
    servedAt = new Date().toISOString(),
  ): Promise<AnnotationMeta> {
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

  async claimAnnotation(
    id: string,
    leaseMs = CLAIM_LEASE_MS,
  ): Promise<AnnotationWithPath | null> {
    return this.withLock(id, async () => {
      const annotation = await this.getAnnotation(id);
      if (!annotation) return null;
      const { servedAt, claimedAt } = annotation.meta;
      if (servedAt !== null) return null; // already served
      if (claimedAt !== null && Date.now() - Date.parse(claimedAt) < leaseMs) return null; // live lease
      const meta = { ...annotation.meta, claimedAt: new Date().toISOString() };
      await writeJson(join(this.paths.annotations, id, 'meta.json'), meta);
      await this.logger.event('annotation.claimed', { annotationId: id });
      return { ...annotation, meta };
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
      meta: normalizeSourceLabel(meta),
      screenshotPath: join(root, id, 'screenshot.png'),
    };
  } catch (error) {
    if (isMissingStoreEntry(error)) {
      return null;
    }
    throw error;
  }
}

async function readAnnotation(root: string, id: string): Promise<AnnotationWithPath | null> {
  try {
    const meta = await readJson<AnnotationMeta>(join(root, id, 'meta.json'));
    const normalized = normalizeSourceLabel(meta);
    return {
      meta: { ...normalized, claimedAt: normalized.claimedAt ?? null },
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

function normalizeSourceLabel<T extends { schemaVersion: number; sourceLabel: string }>(
  meta: T & { pageUrl?: string },
): T {
  if (meta.schemaVersion === LEGACY_SCHEMA_VERSION && typeof meta.pageUrl === 'string') {
    const { pageUrl, ...rest } = meta;
    return { ...(rest as T), sourceLabel: pageUrl };
  }
  return meta;
}
