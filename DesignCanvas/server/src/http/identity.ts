// Self-reported daemon identity for /v1/health (ADR-0004 D1: live only, never persisted).
// Computed once per process at module load — do not generate instanceId elsewhere.
import { randomUUID } from 'node:crypto';

export interface DaemonIdentity {
  pid: number;
  instanceId: string;
  startedAt: string;
  serverEntry: string;
}

export const daemonIdentity: DaemonIdentity = {
  pid: process.pid,
  instanceId: randomUUID(),
  startedAt: new Date().toISOString(),
  serverEntry: process.argv[1] ?? '',
};
