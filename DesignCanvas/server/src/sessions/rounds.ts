// What the session registry means for rounds: which one a polling session gets
// next, and which are closed when a session goes away.

import type { AnnotationMeta, AnnotationSession, SessionInfo } from '../shared.js';
import type { ClaimedAnnotation, DesignCanvasStore } from '../store/store.js';
import type { SessionRegistry } from './registry.js';

export const SESSION_ENDED_MESSAGE = 'The Claude Code session ended before this sketch got a reply.';

export function sessionRef(info: SessionInfo): AnnotationSession {
  return { instance: info.instance, sessionId: info.sessionId, folder: info.folder };
}

/**
 * The oldest round this session should work on, claimed for it: one bound to it,
 * or, when it is the target, one bound to nobody (sent while no session was
 * connected, D5), which this binds. Rounds are tried oldest first so order holds
 * (X4); one that cannot be claimed is skipped, not waited on.
 */
export async function nextRoundFor(
  store: DesignCanvasStore,
  registry: SessionRegistry,
  instance: string,
): Promise<ClaimedAnnotation | null> {
  const info = registry.get(instance);
  if (!info) return null;
  const isTarget = registry.target === instance;
  const annotations = await store.listAnnotations();
  for (const meta of annotations) {
    if (meta.servedAt !== null || meta.reply !== null) continue;
    const mine = meta.session?.instance === instance;
    const unbound = meta.session === undefined && isTarget;
    if (!mine && !unbound) continue;
    const claimed = await store.claimForSession(meta.id, sessionRef(info));
    if (claimed) return claimed;
  }
  return null;
}

/**
 * Fails every unanswered round bound to a session matching `gone` (X6, X26), so the
 * iPad shows an outcome instead of a round that will never move. Returns the
 * updated records for the caller to announce.
 */
export async function failRoundsOfEndedSessions(
  store: DesignCanvasStore,
  gone: (instance: string) => boolean,
): Promise<AnnotationMeta[]> {
  const failed: AnnotationMeta[] = [];
  for (const meta of await store.listAnnotations()) {
    if (meta.reply !== null || !meta.session || !gone(meta.session.instance)) continue;
    const updated = await store.setReply(meta.id, {
      status: 'failed',
      message: SESSION_ENDED_MESSAGE,
      prUrl: null,
      reason: 'session_ended',
    });
    if (updated) failed.push(updated);
  }
  return failed;
}
