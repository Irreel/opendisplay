// The connected Claude Code sessions and which one receives sketches (the target).
// In memory only, on purpose: the daemon restarts with the Mac app, every live mod
// gets a 404 on its next poll and registers again, and that re-registration is all
// "recognised after a relaunch" needs. Pure (the clock is passed in) so the rules
// are testable without a server.

import { basename } from 'node:path';
import {
  SESSION_SETTLE_MS,
  SESSION_STALE_MS,
  type SessionInfo,
  type SessionsSnapshot,
  type SessionState,
} from '../shared.js';

export interface RegisterInput {
  instance: string;
  sessionId: string;
  cwd: string;
  repoRoot?: string;
  branch?: string;
  title?: string;
  startedAt: string;
  modVersion?: string;
  launch?: string;
  /** This session was the target of the daemon it was last registered with. */
  wasTarget?: boolean;
}

export interface PollInput {
  state: SessionState;
  sessionId?: string;
  branch?: string;
  title?: string;
  lastReplyAt?: string;
}

export type TargetChangedBy = 'default' | 'restored' | 'mac' | 'ipad';

export interface RegistryEvents {
  /** The list or the target changed in a way a viewer would see. */
  changed(snapshot: SessionsSnapshot): void;
  log(type: string, fields: Record<string, unknown>): void;
}

interface Entry {
  info: SessionInfo;
  lastSeen: number;
}

export class SessionRegistry {
  private readonly entries = new Map<string, Entry>();
  private targetInstance: string | null = null;
  /** The target was chosen by a rule, not by a person or a restore; see `register`. */
  private targetIsDefault = false;
  /** The target ended with several sessions left: nobody is chosen until a person picks. */
  private pickRequired = false;

  constructor(
    private readonly events: RegistryEvents,
    private readonly startedAt: number = Date.now(),
    private readonly settleMs: number = SESSION_SETTLE_MS,
    private readonly staleMs: number = SESSION_STALE_MS,
  ) {}

  get size(): number {
    return this.entries.size;
  }

  get target(): string | null {
    return this.targetInstance;
  }

  has(instance: string): boolean {
    return this.entries.has(instance);
  }

  get(instance: string): SessionInfo | null {
    return this.entries.get(instance)?.info ?? null;
  }

  settled(now: number): boolean {
    return now - this.startedAt >= this.settleMs;
  }

  snapshot(): SessionsSnapshot {
    const sessions = [...this.entries.values()]
      .map((entry) => entry.info)
      .sort((a, b) => a.startedAt.localeCompare(b.startedAt));
    return { sessions, target: this.targetInstance };
  }

  register(input: RegisterInput, now: number): { target: boolean } {
    const existing = this.entries.get(input.instance);
    const info: SessionInfo = {
      instance: input.instance,
      sessionId: input.sessionId,
      cwd: input.cwd,
      folder: basename(input.repoRoot ?? input.cwd) || input.cwd,
      startedAt: input.startedAt,
      state: existing?.info.state ?? 'idle',
      ...(input.branch ? { branch: input.branch } : {}),
      ...(input.title ? { title: input.title } : {}),
      ...(existing?.info.lastReplyAt ? { lastReplyAt: existing.info.lastReplyAt } : {}),
      ...(input.modVersion ? { modVersion: input.modVersion } : {}),
      ...(input.launch ? { launch: input.launch } : {}),
    };
    this.entries.set(input.instance, { info, lastSeen: now });
    if (!existing) {
      this.events.log('session.registered', {
        instance: info.instance,
        sessionId: info.sessionId,
        folder: info.folder,
        launched: info.launch !== undefined,
      });
    }

    if (input.wasTarget && (this.targetInstance === null || this.targetIsDefault)) {
      // It held the target before the daemon restarted. That outranks a default,
      // and outranks "pick one", which was only ever asked because it was absent.
      this.setTargetInternal(input.instance, 'restored');
      this.targetIsDefault = false;
      this.pickRequired = false;
    } else {
      this.applyDefault(now);
    }
    this.events.changed(this.snapshot());
    return { target: this.targetInstance === input.instance };
  }

  /** Null for an instance this daemon does not know: the mod registers again. */
  poll(instance: string, input: PollInput, now: number): { target: boolean } | null {
    const entry = this.entries.get(instance);
    if (!entry) return null;
    entry.lastSeen = now;
    const before = entry.info;
    const next: SessionInfo = { ...before, state: input.state };
    if (input.sessionId) next.sessionId = input.sessionId;
    if (input.branch !== undefined) setOrDrop(next, 'branch', input.branch);
    if (input.title !== undefined) setOrDrop(next, 'title', input.title);
    if (input.lastReplyAt) next.lastReplyAt = input.lastReplyAt;
    if (!sameInfo(before, next)) {
      entry.info = next;
      if (before.state !== next.state) {
        this.events.log('session.state', { instance, state: next.state });
      }
      this.events.changed(this.snapshot());
    }
    return { target: this.targetInstance === instance };
  }

  remove(instance: string, cause: 'deregistered' | 'stale', now: number): SessionInfo | null {
    const entry = this.entries.get(instance);
    if (!entry) return null;
    this.entries.delete(instance);
    this.events.log('session.ended', { instance, cause });
    if (this.targetInstance === instance) {
      this.targetInstance = null;
      this.targetIsDefault = false;
      // X26: one session left takes over; several left means a person picks.
      this.pickRequired = this.entries.size > 1;
      if (this.pickRequired) this.events.log('target.changed', { target: null, by: 'default' });
    }
    if (this.entries.size <= 1) this.pickRequired = false;
    this.applyDefault(now);
    this.events.changed(this.snapshot());
    return entry.info;
  }

  /** Removes every session that stopped polling; returns them. */
  sweep(now: number): SessionInfo[] {
    const stale = [...this.entries.entries()]
      .filter(([, entry]) => now - entry.lastSeen > this.staleMs)
      .map(([instance]) => instance);
    const removed: SessionInfo[] = [];
    for (const instance of stale) {
      const info = this.remove(instance, 'stale', now);
      if (info) removed.push(info);
    }
    return removed;
  }

  setTarget(instance: string, by: 'mac' | 'ipad'): boolean {
    if (!this.entries.has(instance)) return false;
    this.pickRequired = false;
    this.targetIsDefault = false;
    if (this.targetInstance !== instance) {
      this.setTargetInternal(instance, by);
      this.events.changed(this.snapshot());
    }
    return true;
  }

  /**
   * X21/X22. One session is the target. With several and none chosen, the default
   * is a session the Mac app launched, else the most recently started. Once set it
   * is sticky, with one exception: while sessions are still re-registering after a
   * daemon restart, a default is revised as better candidates arrive, since the
   * order they come back in means nothing.
   */
  private applyDefault(now: number): void {
    if (this.entries.size === 0 || this.pickRequired) return;
    const revisable = this.targetIsDefault && !this.settled(now);
    if (this.targetInstance !== null && !revisable) return;
    const best = [...this.entries.values()]
      .map((entry) => entry.info)
      .sort((a, b) => {
        const launched = Number(b.launch !== undefined) - Number(a.launch !== undefined);
        return launched !== 0 ? launched : b.startedAt.localeCompare(a.startedAt);
      })[0];
    if (!best || best.instance === this.targetInstance) return;
    this.setTargetInternal(best.instance, 'default');
    this.targetIsDefault = true;
  }

  private setTargetInternal(instance: string, by: TargetChangedBy): void {
    this.targetInstance = instance;
    this.events.log('target.changed', { target: instance, by });
  }
}

function setOrDrop(info: SessionInfo, key: 'branch' | 'title', value: string): void {
  if (value.length > 0) info[key] = value;
  else delete info[key];
}

function sameInfo(a: SessionInfo, b: SessionInfo): boolean {
  return (
    a.state === b.state &&
    a.sessionId === b.sessionId &&
    a.branch === b.branch &&
    a.title === b.title &&
    a.lastReplyAt === b.lastReplyAt
  );
}
