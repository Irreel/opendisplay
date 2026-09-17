import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import {
  type AnnotationDevice,
  type AnnotationUploadResponse,
  type HealthResponse,
  HTTP_PATHS,
  REPLY_STATUSES,
  type ReplyStatus,
  SERVER_PORT,
  type Viewport,
  type ZoomRect,
} from '../shared.js';
import type { Logger } from '../log.js';
import type { CreateAnnotationInput, DesignCanvasStore, SetReplyInput } from '../store/store.js';
import { UnknownCaptureError } from '../store/store.js';
import { AnnotationEventBus, isLoopback, openAnnotationStream } from './event-stream.js';
import { daemonIdentity } from './identity.js';
import {
  BodyTooLargeError,
  parseMultipart,
  partBuffer,
  partText,
  readRequestBody,
} from './multipart.js';

const LOOPBACK_HOST = '127.0.0.1';

export interface HttpServerOptions {
  port?: number;
  version: string;
  store: DesignCanvasStore;
  bus: AnnotationEventBus;
  logger: Logger;
}

interface ResolvedHttpServerOptions extends HttpServerOptions {
  resolvedPort: number;
}

export async function startHttpServer(options: HttpServerOptions): Promise<Server> {
  const port = options.port ?? Number(process.env['SERVER_PORT'] ?? SERVER_PORT);
  const resolvedOptions: ResolvedHttpServerOptions = {
    ...options,
    resolvedPort: port,
  };
  const server = createServer((request, response) => {
    handleRequest(request, response, resolvedOptions).catch((error: unknown) => {
      sendError(response, error);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, LOOPBACK_HOST, () => {
      server.off('error', reject);
      const address = server.address();
      if (address && typeof address === 'object') {
        resolvedOptions.resolvedPort = address.port;
      }
      resolve();
    });
  });
  await options.logger.event('server.started', {
    host: LOOPBACK_HOST,
    port,
  });
  return server;
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  options: ResolvedHttpServerOptions,
): Promise<void> {
  const started = Date.now();
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? '127.0.0.1'}`);
  const method = request.method ?? 'GET';
  await options.logger.event('http.request', { method, path: url.pathname });

  try {
    await route(method, url, request, response, options);
  } finally {
    await options.logger.event('http.response', {
      method,
      path: url.pathname,
      statusCode: response.statusCode,
      durationMs: Date.now() - started,
    });
  }
}

async function route(
  method: string,
  url: URL,
  request: IncomingMessage,
  response: ServerResponse,
  options: ResolvedHttpServerOptions,
): Promise<void> {
  if (!requireLoopback(request, response)) return;

  if (method === 'GET' && url.pathname === HTTP_PATHS.health) {
    const body: HealthResponse = {
      status: 'ok',
      version: options.version,
      channelAttached: options.bus.subscriberCount > 0,
      ...daemonIdentity,
      port: options.resolvedPort,
      channelCount: options.bus.subscriberCount,
      channelAttachedAt: options.bus.oldestAttachedAt,
    };
    sendJson(response, 200, body);
    return;
  }

  if (method === 'POST' && url.pathname === HTTP_PATHS.captures) {
    const upload = await parseCaptureUpload(request);
    const meta = await options.store.createCapture(upload);
    sendJson(response, 201, { captureId: meta.id });
    return;
  }

  if (method === 'POST' && url.pathname === HTTP_PATHS.annotations) {
    const upload = await parseAnnotationUpload(request);
    let meta;
    try {
      meta = await options.store.createAnnotation(upload);
    } catch (error) {
      if (error instanceof UnknownCaptureError) {
        sendJson(response, 404, {
          error: 'capture_not_found',
          message: `No capture with id ${error.sourceCaptureId}.`,
        });
        return;
      }
      throw error;
    }
    options.bus.emitPending(meta.id);
    const body: AnnotationUploadResponse = {
      annotationId: meta.id,
      dispatched: options.bus.subscriberCount > 0,
    };
    sendJson(response, 201, body);
    return;
  }

  if (method === 'GET' && url.pathname === HTTP_PATHS.annotations) {
    sendJson(response, 200, { annotations: await options.store.listAnnotations() });
    return;
  }

  const claimMatch = /^\/v1\/annotations\/([^/]+)\/claim$/.exec(url.pathname);
  if (method === 'POST' && claimMatch?.[1]) {
    const claimed = await options.store.claimAnnotation(claimMatch[1]);
    if (!claimed) {
      sendJson(response, 409, {
        error: 'already_claimed',
        message: 'Annotation is served or being served.',
      });
      return;
    }
    sendJson(response, 200, { meta: claimed.meta, compositePath: claimed.compositePath });
    return;
  }

  const servedMatch = /^\/v1\/annotations\/([^/]+)\/served$/.exec(url.pathname);
  if (method === 'POST' && servedMatch?.[1]) {
    const existing = await options.store.getAnnotation(servedMatch[1]);
    if (!existing) {
      sendJson(response, 404, { error: 'annotation_not_found', message: 'Annotation not found.' });
      return;
    }
    const meta = await options.store.markAnnotationServed(servedMatch[1]);
    sendJson(response, 200, { meta });
    return;
  }

  const replyMatch = /^\/v1\/annotations\/([^/]+)\/reply$/.exec(url.pathname);
  if (method === 'POST' && replyMatch?.[1]) {
    const id = replyMatch[1];
    const existing = await options.store.getAnnotation(id);
    if (!existing) {
      sendJson(response, 404, { error: 'annotation_not_found', message: 'Annotation not found.' });
      return;
    }
    const reply = await parseReplyBody(request);
    const updated = await options.store.setReply(id, reply);
    if (!updated) {
      sendJson(response, 409, {
        error: 'already_replied',
        message: 'A reply was already recorded for this annotation.',
      });
      return;
    }
    sendJson(response, 200, { meta: updated });
    return;
  }

  const annotationMatch = /^\/v1\/annotations\/([^/]+)$/.exec(url.pathname);
  if (method === 'DELETE' && annotationMatch?.[1]) {
    const deleted = await options.store.deleteAnnotation(annotationMatch[1]);
    sendJson(
      response,
      deleted ? 200 : 404,
      deleted
        ? { deleted: true }
        : { error: 'annotation_not_found', message: 'Annotation not found.' },
    );
    return;
  }

  if (method === 'GET' && url.pathname === HTTP_PATHS.annotationStream) {
    openAnnotationStream(request, response, options.bus);
    return;
  }

  sendJson(response, 404, {
    error: 'not_found',
    message: `${method} ${url.pathname} is not implemented.`,
  });
}

async function parseCaptureUpload(request: IncomingMessage) {
  const contentType = request.headers['content-type'] ?? '';
  const body = await readRequestBody(request);
  if (contentType.startsWith('application/json')) {
    const parsed = JSON.parse(body.toString('utf8')) as {
      screenshotBase64: string;
      viewport: Viewport;
      createdAt?: string;
    };
    return {
      screenshot: Buffer.from(parsed.screenshotBase64, 'base64'),
      viewport: requireViewport(parsed.viewport),
      ...(parsed.createdAt ? { createdAt: parsed.createdAt } : {}),
    };
  }
  const parts = parseMultipart(body, contentType);
  const metaText = partText(parts, 'meta');
  const screenshot = partBuffer(parts, 'screenshot');
  if (!metaText || !screenshot) {
    throw new HttpError(
      400,
      'invalid_request',
      'Capture upload requires screenshot and meta parts.',
    );
  }
  const meta = JSON.parse(metaText) as {
    viewport: Viewport;
    createdAt?: string;
  };
  return {
    screenshot,
    viewport: requireViewport(meta.viewport),
    ...(meta.createdAt ? { createdAt: meta.createdAt } : {}),
  };
}

async function parseAnnotationUpload(request: IncomingMessage): Promise<CreateAnnotationInput> {
  const contentType = request.headers['content-type'] ?? '';
  const body = await readRequestBody(request);
  if (contentType.startsWith('application/json')) {
    const parsed = JSON.parse(body.toString('utf8')) as {
      compositeBase64: string;
      sketchBase64: string;
      sourceCaptureId: string;
      viewport: Viewport;
      zoomRect: ZoomRect | null;
      note?: { text?: string | null };
      device: AnnotationDevice;
      createdAt?: string;
    };
    return {
      composite: Buffer.from(parsed.compositeBase64, 'base64'),
      sketch: Buffer.from(requireString(parsed.sketchBase64, 'sketchBase64'), 'base64'),
      sourceCaptureId: requireString(parsed.sourceCaptureId, 'sourceCaptureId'),
      viewport: requireViewport(parsed.viewport),
      zoomRect: requireZoomRect(parsed.zoomRect),
      note: requireNote(parsed.note),
      device: requireDevice(parsed.device),
      ...(parsed.createdAt ? { createdAt: parsed.createdAt } : {}),
    };
  }
  const parts = parseMultipart(body, contentType);
  const metaText = partText(parts, 'meta');
  const composite = partBuffer(parts, 'composite');
  const sketch = partBuffer(parts, 'sketch');
  if (!metaText || !composite || !sketch) {
    throw new HttpError(
      400,
      'invalid_request',
      'Annotation upload requires composite, sketch, and meta parts.',
    );
  }
  const meta = JSON.parse(metaText) as {
    sourceCaptureId: string;
    viewport: Viewport;
    zoomRect: ZoomRect | null;
    note?: { text?: string | null };
    device: AnnotationDevice;
    createdAt?: string;
  };
  return {
    composite,
    sketch,
    sourceCaptureId: requireString(meta.sourceCaptureId, 'sourceCaptureId'),
    viewport: requireViewport(meta.viewport),
    zoomRect: requireZoomRect(meta.zoomRect),
    note: requireNote(meta.note),
    device: requireDevice(meta.device),
    ...(meta.createdAt ? { createdAt: meta.createdAt } : {}),
  };
}

async function parseReplyBody(request: IncomingMessage): Promise<SetReplyInput> {
  const body = await readRequestBody(request);
  let parsed: unknown;
  try {
    parsed = JSON.parse(body.toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid_request', 'Reply body must be valid JSON.');
  }
  if (typeof parsed !== 'object' || parsed === null) {
    throw new HttpError(400, 'invalid_request', 'Reply body must be a JSON object.');
  }
  const status = 'status' in parsed ? parsed.status : undefined;
  if (typeof status !== 'string' || !(REPLY_STATUSES as readonly string[]).includes(status)) {
    throw new HttpError(
      400,
      'invalid_request',
      `status must be one of ${REPLY_STATUSES.join(', ')}.`,
    );
  }
  const message = 'message' in parsed ? parsed.message : undefined;
  if (message !== undefined && typeof message !== 'string') {
    throw new HttpError(400, 'invalid_request', 'message must be a string when present.');
  }
  const prUrl = 'prUrl' in parsed ? parsed.prUrl : undefined;
  if (prUrl !== undefined && typeof prUrl !== 'string') {
    throw new HttpError(400, 'invalid_request', 'prUrl must be a string when present.');
  }
  return {
    status: status as ReplyStatus,
    message: message ?? null,
    prUrl: prUrl ?? null,
  };
}

/** Returns false (after sending 403) if the request is not from loopback. Exported for unit tests. */
export function requireLoopback(request: IncomingMessage, response: ServerResponse): boolean {
  if (!isLoopback(request)) {
    sendJson(response, 403, { error: 'forbidden', message: 'Loopback only.' });
    return false;
  }
  return true;
}

function sendJson(response: ServerResponse, statusCode: number, body: unknown): void {
  const payload = `${JSON.stringify(body)}\n`;
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
  });
  response.end(payload);
}

function sendError(response: ServerResponse, error: unknown): void {
  if (response.headersSent) {
    response.destroy(error instanceof Error ? error : undefined);
    return;
  }
  if (error instanceof HttpError) {
    sendJson(response, error.statusCode, { error: error.code, message: error.message });
    return;
  }
  if (error instanceof BodyTooLargeError) {
    sendJson(response, 413, { error: 'body_too_large', message: error.message });
    return;
  }
  const message = error instanceof Error ? error.message : 'Unknown server error';
  sendJson(response, 500, { error: 'internal_error', message });
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new HttpError(400, 'invalid_request', `${field} must be a non-empty string.`);
  }
  return value;
}

function requireViewport(value: unknown): Viewport {
  if (
    typeof value !== 'object' ||
    value === null ||
    !('w' in value) ||
    !('h' in value) ||
    typeof value.w !== 'number' ||
    typeof value.h !== 'number'
  ) {
    throw new HttpError(400, 'invalid_request', 'viewport must include numeric w and h.');
  }
  const scale = 'scale' in value ? value.scale : undefined;
  if (scale !== undefined && typeof scale !== 'number') {
    throw new HttpError(400, 'invalid_request', 'viewport.scale must be a number when present.');
  }
  return scale === undefined ? { w: value.w, h: value.h } : { w: value.w, h: value.h, scale };
}

function requireZoomRect(value: unknown): ZoomRect | null {
  if (value === null) return null;
  if (
    typeof value !== 'object' ||
    value === null ||
    !('x' in value) ||
    !('y' in value) ||
    !('w' in value) ||
    !('h' in value) ||
    typeof value.x !== 'number' ||
    typeof value.y !== 'number' ||
    typeof value.w !== 'number' ||
    typeof value.h !== 'number'
  ) {
    throw new HttpError(400, 'invalid_request', 'zoomRect must be null or {x,y,w,h} numbers.');
  }
  return { x: value.x, y: value.y, w: value.w, h: value.h };
}

function requireDevice(value: unknown): AnnotationDevice {
  if (
    typeof value !== 'object' ||
    value === null ||
    !('id' in value) ||
    !('name' in value) ||
    typeof value.id !== 'string' ||
    typeof value.name !== 'string'
  ) {
    throw new HttpError(400, 'invalid_request', 'device must include string id and name.');
  }
  return { id: value.id, name: value.name };
}

function requireNote(value: unknown): { text?: string | null } {
  if (value === undefined) return {};
  if (typeof value !== 'object' || value === null) {
    throw new HttpError(400, 'invalid_request', 'note must be an object when present.');
  }
  const text = 'text' in value ? value.text : undefined;
  if (text !== undefined && text !== null && typeof text !== 'string') {
    throw new HttpError(400, 'invalid_request', 'note.text must be a string or null when present.');
  }
  return text === undefined ? {} : { text };
}

class HttpError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}
