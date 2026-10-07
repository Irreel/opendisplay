// Design Canvas mod: the hop between the Design Canvas daemon and this Claude Code
// session (spec/technical_doc-ClaudeMods.md). It polls the daemon once a second,
// starts one turn per sketch, gives Claude one tool to report the outcome with, and
// tells the daemon what the session is doing: busy, waiting on a permission dialog,
// ended.
//
// Plain JavaScript on purpose: Claude Code loads this file as it is, and Node APIs
// are not available inside it. Everything goes through `$`. Claude Code's validator
// wants `$` spelled `$.noun.method(...)` at every call site, so helpers take `$` and
// call it that way. The functions exported besides `register` use no `$` at all and
// are what mod/test/ exercises.

export const MOD_VERSION = '0.1.0'
// The plugin is named `designcanvas`, not `design-canvas`, on purpose. Claude Code
// serves a mod's tools as an MCP server named after the plugin, and `design-canvas`
// is the name earlier versions of the app wrote into projects' `.mcp.json` for the
// old channel. In a project that still has that entry the two collided, the tool
// never appeared, and the session never connected (found 2026-10-06).
export const REPLY_TOOL = 'mcp__designcanvas__reply'
export const DEFAULT_PORT = 47100
export const MAC_BUNDLE_ID = 'com.designcanvas.mac'
const TICK_MS = 1000
/** Ticks skipped between attempts while the daemon is unreachable, at most. */
const MAX_BACKOFF_TICKS = 5
const REPLY_STATUSES = ['applied', 'failed', 'needs_input']
const PR_URL_MAX_LENGTH = 2048

export const NO_REPLY_MESSAGE = 'Claude did not reply to this sketch.'
export const INTERRUPTED_MESSAGE = 'Stopped at the Mac before Claude replied.'
export const SESSION_ENDED_MESSAGE = 'The Claude Code session ended before this sketch got a reply.'
export const APP_MISSING_NOTICE =
  'Design Canvas is not installed on this Mac, so sketches cannot reach this session. Install the app, or turn the mod off in its Settings.'

const REPLY_DESCRIPTION =
  'Report the outcome of applying one Design Canvas annotation. Call this exactly once per ' +
  'annotation you were sent, after you have applied (or attempted to apply) the requested ' +
  'change: status "applied" when the change was made, "failed" when it could not be, or ' +
  '"needs_input" when you need more information from the person who drew it. Include a short ' +
  'message describing what happened, and pr_url when the change went out as a pull request. ' +
  'An annotation that says "blank canvas" is a freehand sketch on a blank page, not a ' +
  'screenshot of the running app: read it together with its note.'

const REPLY_SCHEMA = {
  type: 'object',
  required: ['annotation_id', 'status'],
  properties: {
    annotation_id: { type: 'string', description: 'The annotation id from the message.' },
    status: { type: 'string', enum: REPLY_STATUSES },
    message: { type: 'string', description: 'A short human-readable summary of the outcome.' },
    pr_url: { type: 'string', description: 'The pull request URL, when one was opened.' },
  },
}

// MARK: - Pure logic (no `$`)

/** The turn's prompt for one round: the channel's notification text, tool renamed. */
export function promptText(round) {
  const meta = round.meta
  const device = meta.device && meta.device.name ? meta.device.name : 'unknown iPad'
  const note = meta.note && meta.note.text && meta.note.text.trim() ? meta.note.text.trim() : '(none)'
  if (meta.base === 'blank') {
    return [
      'New sketch from iPad (blank canvas).',
      `Annotation ID: ${meta.id}`,
      `Device: ${device}`,
      `Sent at: ${meta.createdAt}`,
      `Composite PNG path: ${round.compositePath}`,
      `Note: ${note}`,
      '',
      'This is a freehand sketch drawn on a blank page, not a screenshot of the running app.',
      `Inspect the composite PNG path to see it, read it together with the note, and act on it in this project, then call ${REPLY_TOOL} exactly once with the outcome.`,
    ].join('\n')
  }
  const z = meta.zoomRect
  const zoom = z ? `x=${z.x.toFixed(3)} y=${z.y.toFixed(3)} w=${z.w.toFixed(3)} h=${z.h.toFixed(3)}` : 'full frame'
  return [
    'New annotation from iPad.',
    `Annotation ID: ${meta.id}`,
    `Device: ${device}`,
    `Captured at: ${round.capturedAt}`,
    `Sent at: ${meta.createdAt}`,
    `Composite PNG path: ${round.compositePath}`,
    `Zoom region: ${zoom}`,
    `Note: ${note}`,
    '',
    'Inspect the composite PNG path to see the visual annotation.',
    `Apply this annotation to the source code, then call ${REPLY_TOOL} exactly once with the outcome.`,
  ].join('\n')
}

export function reminderText(annotationId) {
  return `You have not reported an outcome for Design Canvas annotation ${annotationId}. Call ${REPLY_TOOL} now with applied, failed or needs_input.`
}

/** Only http(s) with a host, bounded: the URL ends up as a tappable link on the iPad. */
export function isAllowedPrUrl(value) {
  if (value.length > PR_URL_MAX_LENGTH) return false
  const match = /^(https?):\/\/([^/?#\s]+)/i.exec(value)
  return match !== null && !/\s/.test(value)
}

/**
 * The reply tool's arguments as Claude sent them. Liberal about extra keys (models
 * send them). Returns `{ error }` with a sentence Claude can act on.
 */
export function parseReplyArgs(raw) {
  if (typeof raw !== 'object' || raw === null) {
    return { error: 'Arguments must be an object with annotation_id and status.' }
  }
  const idRaw = raw.annotation_id
  if (typeof idRaw !== 'string' || idRaw.trim().length === 0) {
    return { error: 'annotation_id must be a non-empty string.' }
  }
  if (typeof raw.status !== 'string' || !REPLY_STATUSES.includes(raw.status)) {
    return { error: `status must be one of: ${REPLY_STATUSES.join(', ')}.` }
  }
  if (raw.message !== undefined && typeof raw.message !== 'string') {
    return { error: 'message must be a string.' }
  }
  if (raw.pr_url !== undefined && typeof raw.pr_url !== 'string') {
    return { error: 'pr_url must be a string.' }
  }
  if (typeof raw.pr_url === 'string' && raw.pr_url.length > 0 && !isAllowedPrUrl(raw.pr_url)) {
    return { error: `pr_url must be an http(s) URL of at most ${PR_URL_MAX_LENGTH} characters.` }
  }
  const body = { status: raw.status }
  if (typeof raw.message === 'string' && raw.message.length > 0) body.message = raw.message
  if (typeof raw.pr_url === 'string' && raw.pr_url.length > 0) body.prUrl = raw.pr_url
  return { annotationId: idRaw.trim(), body }
}

/** What Claude reads back from the reply tool for the daemon's answer. */
export function replyResultText(status) {
  if (status >= 200 && status < 300) return 'Reply recorded.'
  if (status === 409) return 'A reply was already recorded for this annotation.'
  if (status === 404) return 'Unknown annotation id.'
  if (status === 400) return 'The Design Canvas daemon rejected this reply as invalid.'
  return 'Could not reach the Design Canvas daemon.'
}

/** The round in flight, as the mod tracks it. */
export function newRound(claimed) {
  return {
    id: claimed.meta.id,
    compositePath: claimed.compositePath,
    /** The turn judged for an outcome: the round's own, then the reminder's. */
    turnId: null,
    reminded: false,
  }
}

/**
 * A turn began. If its text names the round in flight it is that round's turn (or
 * its reminder's). Other turns run in the same session, the user's own prompts and
 * the ones Claude Code starts for a background task, and must not be mistaken for it.
 */
export function noteTurnStart(round, e) {
  if (round && typeof e.text === 'string' && e.text.includes(round.id)) round.turnId = e.turnId
}

/**
 * X6. What to do when a turn of the main agent ends. `none` for any turn that is
 * not the round's. The round's turn with no outcome: one reminder, then failed. A
 * turn the user stopped by hand: failed at once, since a reminder would restart
 * what they just stopped.
 */
export function onTurnComplete(round, e) {
  if (!round || e.agentId || round.turnId === null || e.turnId !== round.turnId) return { action: 'none' }
  if (e.isAborted) return { action: 'fail', reason: 'interrupted', message: INTERRUPTED_MESSAGE }
  if (!round.reminded) return { action: 'remind' }
  return { action: 'fail', reason: 'no_reply', message: NO_REPLY_MESSAGE }
}

/**
 * X7. A Read is approved on the user's behalf only when it would otherwise ask, a
 * round is in flight, and the path is exactly that round's composite. Exact string
 * equality: no path arithmetic, no symlinks, and nothing at all between rounds. A
 * deny is never touched.
 */
export function allowsSketchRead(decision, round, filePath) {
  return decision === 'ask' && round !== null && typeof filePath === 'string' && filePath === round.compositePath
}

/**
 * X8. Which tool calls are standing at a permission decision. `tool.check`
 * resolving to "ask" marks a call; the permission request (which carries no call
 * id) says a dialog really opened, which in auto mode it does not; the call
 * finishing unmarks it. Per call, because Claude runs tools in parallel and another
 * tool returning must not end the wait while the dialog is still up.
 */
export function newWaitTracker() {
  return { asked: new Set(), dialogOpen: false }
}
export function waitAsked(tracker, toolUseId) {
  if (toolUseId) tracker.asked.add(toolUseId)
}
export function waitDialogOpened(tracker) {
  tracker.dialogOpen = true
}
export function waitCallFinished(tracker, toolUseId) {
  tracker.asked.delete(toolUseId)
  if (tracker.asked.size === 0) tracker.dialogOpen = false
}
export function waitReset(tracker) {
  tracker.asked.clear()
  tracker.dialogOpen = false
}
export function isWaiting(tracker) {
  return tracker.dialogOpen && tracker.asked.size > 0
}

/** The .app this mod is bundled in, when it is; an installed copy lives elsewhere. */
export function appPathFromRoot(root) {
  const match = /^(.*\.app)\/Contents\//.exec(typeof root === 'string' ? root : '')
  return match ? match[1] : null
}

export function openAppArgv(root) {
  const app = appPathFromRoot(root)
  // -g: do not take the terminal's place in front.
  return app ? ['open', '-g', app] : ['open', '-g', '-b', MAC_BUNDLE_ID]
}

/** 1, 2, ... ticks between attempts while the daemon is down, capped. */
export function backoffTicks(failures) {
  return Math.min(Math.max(failures, 0), MAX_BACKOFF_TICKS)
}

export function newInstanceId(random = Math.random) {
  let id = ''
  while (id.length < 24) id += Math.floor(random() * 36).toString(36)
  return `dc-${id}`
}

// MARK: - Session state (module scope: survives /clear, reset by a reload)

function freshState() {
  return {
    instance: newInstanceId(),
    startedAt: new Date().toISOString(),
    base: `http://127.0.0.1:${DEFAULT_PORT}`,
    launch: undefined,
    registered: false,
    /** The reply tool is registered. Without it a round could never be answered. */
    toolReady: false,
    target: false,
    turnRunning: false,
    wait: newWaitTracker(),
    round: null,
    /** A claim was handed over and its prompt is on its way to becoming a turn. */
    submitting: false,
    /** Outcomes the daemon was not there to take; posted when it is back. */
    unsent: [],
    title: '',
    branch: '',
    lastReplyAt: undefined,
    lastReported: '',
    ticking: false,
    failures: 0,
    skip: 0,
    /** The tick's timer: `$.clock.every` returns `{ cancel }`, not a function. */
    timer: null,
  }
}

let S = freshState()

function stopTicking() {
  if (S.timer) S.timer.cancel()
  S.timer = null
}

function sessionState() {
  if (isWaiting(S.wait)) return 'waiting'
  return S.turnRunning ? 'busy' : 'idle'
}

// MARK: - Daemon calls

async function call($, method, path, body) {
  const init = body === undefined ? { method } : { method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }
  const response = await $.http.fetch(S.base + path, init)
  let json = null
  try {
    json = response.text ? JSON.parse(response.text) : null
  } catch {
    json = null
  }
  return { status: response.status, ok: response.ok, json }
}

/** Posts an outcome; if the daemon is not there, keeps it for the next good tick. */
async function postOutcome($, annotationId, body) {
  try {
    const result = await call($, 'POST', `/v1/annotations/${encodeURIComponent(annotationId)}/reply`, body)
    return result.status
  } catch {
    S.unsent.push({ annotationId, body })
    return 0
  }
}

async function flushUnsent($) {
  while (S.unsent.length > 0) {
    const next = S.unsent[0]
    await call($, 'POST', `/v1/annotations/${encodeURIComponent(next.annotationId)}/reply`, next.body)
    S.unsent.shift()
  }
}

async function registerSession($) {
  const cwd = await $.session.cwd()
  let repoRoot
  try {
    const repo = await $.session.repo()
    repoRoot = repo && repo.root ? repo.root : undefined
  } catch {
    repoRoot = undefined
  }
  const result = await call($, 'POST', '/v1/sessions', {
    instance: S.instance,
    sessionId: await $.session.id(),
    cwd,
    startedAt: S.startedAt,
    modVersion: MOD_VERSION,
    ...(repoRoot ? { repoRoot } : {}),
    ...(S.branch ? { branch: S.branch } : {}),
    ...(S.title ? { title: S.title } : {}),
    ...(S.launch ? { launch: S.launch } : {}),
    ...(S.target ? { wasTarget: true } : {}),
  })
  if (!result.ok) return false
  S.registered = true
  S.target = result.json !== null && result.json.target === true
  // The app is reachable again: a later "not installed" is news once more (XG9).
  await $.store.set('appMissingNotified', false)
  return true
}

/**
 * One poll: the heartbeat, the session's state, and, when the session is idle with
 * nothing in flight, a request for the next round.
 */
async function poll($, want) {
  const state = sessionState()
  const result = await call($, 'POST', `/v1/sessions/${S.instance}/poll`, {
    state,
    want,
    sessionId: await $.session.id(),
    branch: S.branch,
    title: S.title,
    ...(S.lastReplyAt ? { lastReplyAt: S.lastReplyAt } : {}),
  })
  if (result.status === 404) {
    // A new daemon (the Mac app was relaunched). Register again next tick.
    S.registered = false
    return
  }
  if (!result.ok || result.json === null) return
  S.lastReported = state
  S.target = result.json.target === true
  if (want && result.json.round && !S.round) startRound($, result.json.round)
}

/** A state change the iPad should see now, not at the next tick (X8's 2 s). */
function reportSoon($) {
  if (!S.registered || sessionState() === S.lastReported) return
  poll($, false).catch(() => {})
}

// MARK: - Rounds

function startRound($, claimed) {
  const round = newRound(claimed)
  S.round = round
  S.submitting = true
  // Not awaited by the tick: the call resolves only once the session is idle and
  // the turn has begun, which can be as far away as the user's own turn is long.
  $.prompt.submit({ text: promptText(claimed) })
    .then(() => call($, 'POST', `/v1/annotations/${round.id}/served`))
    .catch(() => {
      // The prompt never became a turn. Let go; the daemon hands the round back.
      if (S.round === round) S.round = null
    })
    .finally(() => {
      S.submitting = false
    })
}

async function failRound($, round, reason, message) {
  if (S.round === round) S.round = null
  await postOutcome($, round.id, { status: 'failed', message, reason })
}

async function refreshBranch($) {
  try {
    const result = await $.process.run(['git', 'branch', '--show-current'])
    if (result.exitCode === 0) S.branch = result.stdout.trim()
  } catch {
    // Not a repository, or no git: the list simply shows no branch.
  }
}

// MARK: - Start

async function openMacApp($) {
  let exitCode = 1
  try {
    const result = await $.process.run(openAppArgv($.plugin.root))
    exitCode = result.exitCode
  } catch {
    exitCode = 1
  }
  if (exitCode === 0) return
  // X19/XG9: say it once, for every session on this Mac, then stay silent.
  if ((await $.store.get('appMissingNotified')) === true) return
  await $.store.set('appMissingNotified', true)
  $.ui.toast(APP_MISSING_NOTICE, { timeoutMs: 12000 })
}

async function ensureReplyTool($) {
  if (S.toolReady) return
  await $.tool.register({ name: 'reply', description: REPLY_DESCRIPTION, inputSchema: REPLY_SCHEMA })
  S.toolReady = true
}

async function tick($) {
  if (S.ticking) return
  if (S.skip > 0) {
    S.skip -= 1
    return
  }
  S.ticking = true
  try {
    // No tool, no session: a session that cannot report an outcome must not be
    // offered sketches. Tried again on each attempt, with the same backoff.
    await ensureReplyTool($)
    if (!S.registered && !(await registerSession($))) throw new Error('not registered')
    await flushUnsent($)
    await poll($, !S.turnRunning && !isWaiting(S.wait) && S.round === null && !S.submitting)
    S.failures = 0
  } catch {
    // The daemon is not there: the Mac app is quit or restarting. Quietly back off.
    S.failures += 1
    S.skip = backoffTicks(S.failures)
  } finally {
    S.ticking = false
  }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    try {
      stopTicking()
      // classic.SessionStart, which carries the title, fires before this hook.
      const title = S.title
      S = freshState()
      S.title = title
      const port = Number(await $.env.get('DESIGN_CANVAS_PORT'))
      if (Number.isInteger(port) && port > 0) S.base = `http://127.0.0.1:${port}`
      S.launch = (await $.env.get('DESIGN_CANVAS_LAUNCH')) || undefined
      // Its own guard, and the tick is started whatever happens here: one failed
      // step used to leave the session loaded, silent and never connected.
      try {
        await ensureReplyTool($)
      } catch {
        // The tick tries again.
      }
      await refreshBranch($)
      let reachable = false
      try {
        reachable = (await call($, 'GET', '/v1/health')).ok
      } catch {
        reachable = false
      }
      // X19: opened only here. An app the user quits mid-session stays quit.
      if (!reachable) await openMacApp($)
      S.timer = $.clock.every(TICK_MS, () => {
        tick($)
      })
    } catch {
      // Design Canvas is plumbing: whatever went wrong here, the session goes on.
    }
    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    S.title = typeof e.session_title === 'string' ? e.session_title : ''
    return next(e)
  })

  on('classic.UserPromptSubmit', async ($, e, next) => {
    S.title = typeof e.session_title === 'string' ? e.session_title : ''
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    S.turnRunning = true
    noteTurnStart(S.round, e)
    reportSoon($)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId) return next(e)
    try {
      S.turnRunning = false
      waitReset(S.wait)
      S.lastReplyAt = new Date().toISOString()
      const round = S.round
      const verdict = onTurnComplete(round, e)
      if (verdict.action === 'remind') {
        round.reminded = true
        round.turnId = null
        call($, 'POST', `/v1/annotations/${round.id}/reminded`).catch(() => {})
        $.prompt.submit({ text: reminderText(round.id) }).catch(() => {})
      } else if (verdict.action === 'fail') {
        await failRound($, round, verdict.reason, verdict.message)
      }
      await refreshBranch($)
      reportSoon($)
    } catch {
      // Never let bookkeeping break the end of a turn.
    }
    return next(e)
  })

  // Wraps every tool call, to see when one that stood at a permission dialog is over.
  on('tool.call', async ($, e, next) => {
    try {
      return await next(e)
    } finally {
      if (e.tool !== REPLY_TOOL && e.tool_use_id) {
        waitCallFinished(S.wait, e.tool_use_id)
        reportSoon($)
      }
    }
  })

  // The reply tool. Answered here, without `next`, so it never reaches a permission
  // decision: reporting an outcome asks nothing of the user.
  on('tool.call', { tool: REPLY_TOOL }, async ($, e) => {
    const parsed = parseReplyArgs(e)
    if (parsed.error) return { result: parsed.error }
    const status = await postOutcome($, parsed.annotationId, parsed.body)
    // 0: the daemon was away and the outcome is queued. It is recorded as far as
    // Claude is concerned; asking it to retry would only produce a duplicate.
    if (status === 0 || (status >= 200 && status < 300) || status === 409) {
      if (S.round && S.round.id === parsed.annotationId) S.round = null
    }
    return { result: replyResultText(status === 0 ? 200 : status) }
  })

  on('tool.check', async ($, e, next) => {
    const decided = await next(e)
    try {
      if (decided && decided.decision === 'ask') {
        const path = e.input && typeof e.input === 'object' ? e.input.file_path : undefined
        if (e.tool === 'Read' && allowsSketchRead(decided.decision, S.round, path)) {
          return { decision: 'allow', reason: 'Design Canvas: the sketch for the round in progress' }
        }
        waitAsked(S.wait, e.tool_use_id)
      }
    } catch {
      // Fall through to what Claude Code decided.
    }
    return decided
  })

  on('classic.PermissionRequest', async ($, e, next) => {
    waitDialogOpened(S.wait)
    reportSoon($)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    try {
      S.turnRunning = false
      waitReset(S.wait)
      const round = S.round
      if (e.reason === 'clear' || e.reason === 'resume') {
        // The conversation ended, not the process: close the round, stay connected.
        if (round) await failRound($, round, 'session_ended', SESSION_ENDED_MESSAGE)
      } else {
        // One request, because every session.end hook on the machine shares 1.5 s:
        // deregistering makes the daemon close this session's unanswered rounds.
        S.round = null
        stopTicking()
        const wasRegistered = S.registered
        S.registered = false
        if (wasRegistered) await call($, 'DELETE', `/v1/sessions/${S.instance}`)
      }
    } catch {
      // The daemon's own staleness check covers whatever did not get sent.
    }
    return next(e)
  })
}
