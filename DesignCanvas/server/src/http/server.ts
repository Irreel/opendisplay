import { createReadStream } from 'node:fs';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { networkInterfaces } from 'node:os';
import { basename } from 'node:path';
import {
  type AnnotationUploadResponse,
  type CaptureRecord,
  type HealthResponse,
  HTTP_PATHS,
  SERVER_PORT,
  type Viewport,
} from '../shared.js';
import type { Logger } from '../log.js';
import type { DesignCanvasStore } from '../store/store.js';
import { AnnotationEventBus, isLoopback, openAnnotationStream } from './event-stream.js';
import { daemonIdentity } from './identity.js';
import {
  BodyTooLargeError,
  parseMultipart,
  partBuffer,
  partText,
  readRequestBody,
} from './multipart.js';

export interface HttpServerOptions {
  port?: number;
  host?: string;
  version: string;
  store: DesignCanvasStore;
  bus: AnnotationEventBus;
  logger: Logger;
}

interface ResolvedHttpServerOptions extends HttpServerOptions {
  resolvedHost: string;
  resolvedPort: number;
}

export async function startHttpServer(options: HttpServerOptions): Promise<Server> {
  const host = options.host ?? '127.0.0.1';
  const port = options.port ?? Number(process.env['SERVER_PORT'] ?? SERVER_PORT);
  const resolvedOptions: ResolvedHttpServerOptions = {
    ...options,
    resolvedHost: host,
    resolvedPort: port,
  };
  const server = createServer((request, response) => {
    handleRequest(request, response, resolvedOptions).catch((error: unknown) => {
      sendError(response, error);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      const address = server.address();
      if (address && typeof address === 'object') {
        resolvedOptions.resolvedPort = address.port;
      }
      resolve();
    });
  });
  await options.logger.event('server.started', {
    host,
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
  if (method === 'GET' && url.pathname === HTTP_PATHS.health) {
    const body: HealthResponse = {
      status: 'ok',
      version: options.version,
      channelAttached: options.bus.subscriberCount > 0,
      pairedDevices: 0,
      ipadUrls: ipadUrlsFor(options.resolvedHost, options.resolvedPort),
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

  if (method === 'GET' && url.pathname === HTTP_PATHS.capturesLatest) {
    const latest = await options.store.latestCapture();
    if (!latest) {
      sendJson(response, 404, {
        error: 'capture_not_found',
        message: 'No captures have been uploaded.',
      });
      return;
    }
    const record: CaptureRecord = {
      ...latest.meta,
      pngUrl: `/v1/captures/${latest.meta.id}/screenshot.png`,
    };
    sendJson(response, 200, record);
    return;
  }

  const captureMatch = /^\/v1\/captures\/([^/]+)\/screenshot\.png$/.exec(url.pathname);
  if (method === 'GET' && captureMatch?.[1]) {
    const capture = await options.store.getCapture(captureMatch[1]);
    if (!capture) {
      sendJson(response, 404, { error: 'capture_not_found', message: 'Capture not found.' });
      return;
    }
    streamPng(response, capture.screenshotPath);
    return;
  }

  if (method === 'POST' && url.pathname === HTTP_PATHS.annotations) {
    const upload = await parseAnnotationUpload(request);
    const meta = await options.store.createAnnotation(upload);
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
    if (!requireLoopback(request, response)) return;
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
    if (!requireLoopback(request, response)) return;
    const existing = await options.store.getAnnotation(servedMatch[1]);
    if (!existing) {
      sendJson(response, 404, { error: 'annotation_not_found', message: 'Annotation not found.' });
      return;
    }
    const meta = await options.store.markAnnotationServed(servedMatch[1]);
    sendJson(response, 200, { meta });
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
    if (!requireLoopback(request, response)) return;
    openAnnotationStream(request, response, options.bus);
    return;
  }

  sendJson(response, 404, {
    error: 'not_found',
    message: `${method} ${url.pathname} is not implemented.`,
  });
}

function ipadUrlsFor(host: string, port: number): string[] {
  if (host === '127.0.0.1' || host === 'localhost' || host === '::1') {
    return [];
  }
  if (host !== '0.0.0.0' && host !== '::') {
    return [`http://${host}:${port}`];
  }

  const urls = new Set<string>();
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) {
        urls.add(`http://${entry.address}:${port}`);
      }
    }
  }
  return [...urls].sort();
}

async function parseCaptureUpload(request: IncomingMessage) {
  const contentType = request.headers['content-type'] ?? '';
  const body = await readRequestBody(request);
  if (contentType.startsWith('application/json')) {
    const parsed = JSON.parse(body.toString('utf8')) as {
      screenshotBase64: string;
      sourceLabel?: string;
      pageUrl?: string;
      viewport: Viewport;
      createdAt?: string;
    };
    return {
      screenshot: Buffer.from(parsed.screenshotBase64, 'base64'),
      sourceLabel: requireString(parsed.sourceLabel ?? parsed.pageUrl, 'sourceLabel'),
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
      'invalid_capture_upload',
      'Capture upload requires screenshot and meta parts.',
    );
  }
  const meta = JSON.parse(metaText) as {
    sourceLabel?: string;
    pageUrl?: string;
    viewport: Viewport;
    createdAt?: string;
  };
  return {
    screenshot,
    sourceLabel: requireString(meta.sourceLabel ?? meta.pageUrl, 'sourceLabel'),
    viewport: requireViewport(meta.viewport),
    ...(meta.createdAt ? { createdAt: meta.createdAt } : {}),
  };
}

async function parseAnnotationUpload(request: IncomingMessage) {
  const contentType = request.headers['content-type'] ?? '';
  const body = await readRequestBody(request);
  if (contentType.startsWith('application/json')) {
    const parsed = JSON.parse(body.toString('utf8')) as {
      compositeBase64: string;
      sketchBase64?: string;
      sourceCaptureId: string;
      sourceLabel?: string;
      pageUrl?: string;
      viewport: Viewport;
      note?: { text?: string | null; voiceFile?: string | null };
      createdAt?: string;
    };
    return {
      composite: Buffer.from(parsed.compositeBase64, 'base64'),
      sketch: parsed.sketchBase64 ? Buffer.from(parsed.sketchBase64, 'base64') : null,
      sourceCaptureId: requireString(parsed.sourceCaptureId, 'sourceCaptureId'),
      sourceLabel: requireString(parsed.sourceLabel ?? parsed.pageUrl, 'sourceLabel'),
      viewport: requireViewport(parsed.viewport),
      note: parsed.note ?? {},
      ...(parsed.createdAt ? { createdAt: parsed.createdAt } : {}),
    };
  }
  const parts = parseMultipart(body, contentType);
  const metaText = partText(parts, 'meta');
  const composite = partBuffer(parts, 'composite');
  if (!metaText || !composite) {
    throw new HttpError(
      400,
      'invalid_annotation_upload',
      'Annotation upload requires composite and meta parts.',
    );
  }
  const meta = JSON.parse(metaText) as {
    sourceCaptureId: string;
    sourceLabel?: string;
    pageUrl?: string;
    viewport: Viewport;
    note?: { text?: string | null; voiceFile?: string | null };
    createdAt?: string;
  };
  return {
    composite,
    sketch: partBuffer(parts, 'sketch'),
    noteFile: partBuffer(parts, 'note'),
    sourceCaptureId: requireString(meta.sourceCaptureId, 'sourceCaptureId'),
    sourceLabel: requireString(meta.sourceLabel ?? meta.pageUrl, 'sourceLabel'),
    viewport: requireViewport(meta.viewport),
    note: meta.note ?? {},
    ...(meta.createdAt ? { createdAt: meta.createdAt } : {}),
  };
}

/** Returns false (after sending 403) if the request is not from loopback. */
function requireLoopback(request: IncomingMessage, response: ServerResponse): boolean {
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
    'access-control-allow-origin': '*',
  });
  response.end(payload);
}

function streamPng(response: ServerResponse, path: string): void {
  response.writeHead(200, {
    'content-type': 'image/png',
    'content-disposition': `inline; filename="${basename(path)}"`,
  });
  createReadStream(path).pipe(response);
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
  return { w: value.w, h: value.h };
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
