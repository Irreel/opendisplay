import type { IncomingMessage } from 'node:http';

export interface MultipartPart {
  name: string;
  filename: string | null;
  contentType: string | null;
  data: Buffer;
}

export async function readRequestBody(
  request: IncomingMessage,
  limitBytes = 25 * 1024 * 1024,
): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.byteLength;
    if (total > limitBytes) {
      throw new BodyTooLargeError(limitBytes);
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

export function parseMultipart(body: Buffer, contentType: string): Map<string, MultipartPart> {
  const boundary = getBoundary(contentType);
  if (!boundary) {
    throw new Error('Missing multipart boundary');
  }
  const delimiter = Buffer.from(`--${boundary}`);
  const parts = new Map<string, MultipartPart>();
  let cursor = 0;

  while (cursor < body.length) {
    const boundaryStart = body.indexOf(delimiter, cursor);
    if (boundaryStart === -1) {
      break;
    }
    let partStart = boundaryStart + delimiter.length;
    if (body.subarray(partStart, partStart + 2).toString() === '--') {
      break;
    }
    if (body.subarray(partStart, partStart + 2).toString() === '\r\n') {
      partStart += 2;
    }
    const headerEnd = body.indexOf(Buffer.from('\r\n\r\n'), partStart);
    if (headerEnd === -1) {
      break;
    }
    const headerText = body.subarray(partStart, headerEnd).toString('utf8');
    const dataStart = headerEnd + 4;
    const nextBoundary = body.indexOf(Buffer.from(`\r\n--${boundary}`), dataStart);
    if (nextBoundary === -1) {
      break;
    }
    const data = body.subarray(dataStart, nextBoundary);
    const part = parsePart(headerText, data);
    if (part.name) {
      parts.set(part.name, part);
    }
    cursor = nextBoundary + 2;
  }

  return parts;
}

export function partText(parts: Map<string, MultipartPart>, name: string): string | null {
  const part = parts.get(name);
  return part ? part.data.toString('utf8') : null;
}

export function partBuffer(parts: Map<string, MultipartPart>, name: string): Buffer | null {
  return parts.get(name)?.data ?? null;
}

export class BodyTooLargeError extends Error {
  constructor(readonly limitBytes: number) {
    super(`Request body exceeds ${limitBytes} bytes`);
  }
}

function getBoundary(contentType: string): string | null {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
  return match?.[1] ?? match?.[2] ?? null;
}

function parsePart(headerText: string, data: Buffer): MultipartPart {
  const headers = new Map<string, string>();
  for (const line of headerText.split('\r\n')) {
    const splitAt = line.indexOf(':');
    if (splitAt === -1) {
      continue;
    }
    headers.set(line.slice(0, splitAt).toLowerCase(), line.slice(splitAt + 1).trim());
  }
  const disposition = headers.get('content-disposition') ?? '';
  return {
    name: dispositionParam(disposition, 'name') ?? '',
    filename: dispositionParam(disposition, 'filename'),
    contentType: headers.get('content-type') ?? null,
    data,
  };
}

function dispositionParam(disposition: string, name: string): string | null {
  const match = new RegExp(`${name}="([^"]*)"`, 'i').exec(disposition);
  return match?.[1] ?? null;
}
