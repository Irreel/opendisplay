import { randomBytes } from 'node:crypto';

/**
 * RFC 9562 UUID version 7: a 48-bit big-endian Unix millisecond timestamp
 * followed by random bits, laid out so the hex string sorts lexically in
 * timestamp order. Annotation ids use this (capture ids keep the older
 * sortable id).
 */
export function uuidv7(nowMs: number = Date.now()): string {
  const bytes = new Uint8Array(16);
  const ts = BigInt(Math.floor(nowMs));
  bytes[0] = Number((ts >> 40n) & 0xffn);
  bytes[1] = Number((ts >> 32n) & 0xffn);
  bytes[2] = Number((ts >> 24n) & 0xffn);
  bytes[3] = Number((ts >> 16n) & 0xffn);
  bytes[4] = Number((ts >> 8n) & 0xffn);
  bytes[5] = Number(ts & 0xffn);

  const rand = randomBytes(10);
  // Byte 6: version nibble (0111) + top 4 bits of rand_a.
  bytes[6] = 0x70 | (rand[0]! & 0x0f);
  bytes[7] = rand[1]!;
  // Byte 8: variant bits (10) + top 6 bits of rand_b.
  bytes[8] = 0x80 | (rand[2]! & 0x3f);
  bytes[9] = rand[3]!;
  bytes[10] = rand[4]!;
  bytes[11] = rand[5]!;
  bytes[12] = rand[6]!;
  bytes[13] = rand[7]!;
  bytes[14] = rand[8]!;
  bytes[15] = rand[9]!;

  const hex = Buffer.from(bytes).toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
