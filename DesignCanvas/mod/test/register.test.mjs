// The mod's logic, without Claude Code: the pure functions directly, and the hooks
// against a fake `$` that records what they ask for and plays the daemon.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import * as mod from '../hooks/register.js'

const round = (overrides = {}) => ({
  meta: {
    id: '01a10e5e-635d-7ef7-af35-260fdf9a688d',
    createdAt: '2026-10-05T23:20:29.277Z',
    device: { id: 'd1', name: 'Studio iPad' },
    note: { text: '  make this bigger ' },
    zoomRect: { x: 0.1, y: 0.25, w: 0.5, h: 0.5 },
    ...overrides,
  },
  compositePath: '/store/annotations/01a10e5e/composite.png',
  capturedAt: '2026-10-05T23:20:29.266Z',
})

test('promptText: mirror round carries every line and names the mod tool', () => {
  const text = mod.promptText(round())
  assert.match(text, /^New annotation from iPad\.\nAnnotation ID: 01a10e5e-635d-7ef7-af35-260fdf9a688d\n/)
  assert.match(text, /Device: Studio iPad\n/)
  assert.match(text, /Captured at: 2026-10-05T23:20:29\.266Z\n/)
  assert.match(text, /Composite PNG path: \/store\/annotations\/01a10e5e\/composite\.png\n/)
  assert.match(text, /Zoom region: x=0\.100 y=0\.250 w=0\.500 h=0\.500\n/)
  assert.match(text, /Note: make this bigger\n/)
  assert.match(text, /call mcp__designcanvas__reply exactly once with the outcome\.$/)
})

test('promptText: full frame, no note, unnamed device; blank round omits frame lines', () => {
  const text = mod.promptText(round({ zoomRect: null, note: { text: null }, device: { id: 'd', name: '' } }))
  assert.match(text, /Zoom region: full frame\n/)
  assert.match(text, /Note: \(none\)\n/)
  assert.match(text, /Device: unknown iPad\n/)
  const blank = mod.promptText(round({ base: 'blank' }))
  assert.match(blank, /^New sketch from iPad \(blank canvas\)\./)
  assert.doesNotMatch(blank, /Captured at|Zoom region/)
  assert.match(blank, /not a screenshot of the running app/)
  assert.match(blank, /mcp__designcanvas__reply/)
})

test('parseReplyArgs: accepts the valid shapes and extra keys, rejects the rest in words', () => {
  assert.deepEqual(
    mod.parseReplyArgs({ annotation_id: ' a1 ', status: 'applied', message: 'done', pr_url: 'https://x.dev/pr/1', tool: 't', tool_use_id: 'u' }),
    { annotationId: 'a1', body: { status: 'applied', message: 'done', prUrl: 'https://x.dev/pr/1' } },
  )
  assert.deepEqual(mod.parseReplyArgs({ annotation_id: 'a1', status: 'needs_input', message: '' }), {
    annotationId: 'a1',
    body: { status: 'needs_input' },
  })
  for (const bad of [
    null,
    {},
    { annotation_id: '', status: 'applied' },
    { annotation_id: 'a', status: 'done' },
    { annotation_id: 'a', status: 'applied', message: 3 },
    { annotation_id: 'a', status: 'applied', pr_url: 4 },
    { annotation_id: 'a', status: 'applied', pr_url: 'javascript:alert(1)' },
    { annotation_id: 'a', status: 'applied', pr_url: 'https://' },
    { annotation_id: 'a', status: 'applied', pr_url: `https://x.dev/${'a'.repeat(2100)}` },
  ]) {
    assert.equal(typeof mod.parseReplyArgs(bad).error, 'string', JSON.stringify(bad)?.slice(0, 60))
  }
})

test('replyResultText maps the daemon\'s answers to what Claude reads', () => {
  assert.equal(mod.replyResultText(200), 'Reply recorded.')
  assert.equal(mod.replyResultText(409), 'A reply was already recorded for this annotation.')
  assert.equal(mod.replyResultText(404), 'Unknown annotation id.')
  assert.match(mod.replyResultText(500), /Could not reach/)
})

test('onTurnComplete: only the round\'s own turn is judged (X6)', () => {
  const r = mod.newRound(round())
  assert.deepEqual(mod.onTurnComplete(null, { turnId: 't1' }), { action: 'none' })
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 't1' }), { action: 'none' }, 'no turn seen yet')
  mod.noteTurnStart(r, { turnId: 'user-turn', text: 'what does this repo do?' })
  assert.equal(r.turnId, null, 'a turn that does not name the round is not its turn')
  mod.noteTurnStart(r, { turnId: 't1', text: `The designcanvas plugin sent a message:\n${mod.promptText(round())}` })
  assert.equal(r.turnId, 't1')
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 'background-task' }), { action: 'none' })
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 't1', agentId: 'sub' }), { action: 'none' })
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 't1', isAborted: false }), { action: 'remind' })
  r.reminded = true
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 't1', isAborted: false }), {
    action: 'fail',
    reason: 'no_reply',
    message: mod.NO_REPLY_MESSAGE,
  })
})

test('onTurnComplete: a turn the user stopped fails at once, reminded or not', () => {
  const r = mod.newRound(round())
  r.turnId = 't1'
  assert.deepEqual(mod.onTurnComplete(r, { turnId: 't1', isAborted: true }), {
    action: 'fail',
    reason: 'interrupted',
    message: mod.INTERRUPTED_MESSAGE,
  })
})

test('allowsSketchRead: exact path of the round in flight, only over "ask" (X7)', () => {
  const r = mod.newRound(round())
  assert.equal(mod.allowsSketchRead('ask', r, r.compositePath), true)
  assert.equal(mod.allowsSketchRead('deny', r, r.compositePath), false)
  assert.equal(mod.allowsSketchRead('allow', r, r.compositePath), false)
  assert.equal(mod.allowsSketchRead('ask', null, r.compositePath), false)
  assert.equal(mod.allowsSketchRead('ask', r, `${r.compositePath}/../meta.json`), false)
  assert.equal(mod.allowsSketchRead('ask', r, '/store/annotations/other/composite.png'), false)
  assert.equal(mod.allowsSketchRead('ask', r, undefined), false)
})

test('wait tracker: a dialog must open, and parallel calls end the wait one by one (X8)', () => {
  const w = mod.newWaitTracker()
  mod.waitAsked(w, 'a')
  assert.equal(mod.isWaiting(w), false, 'auto mode: asked, but no dialog')
  mod.waitDialogOpened(w)
  assert.equal(mod.isWaiting(w), true)
  mod.waitCallFinished(w, 'unrelated-parallel-call')
  assert.equal(mod.isWaiting(w), true, 'another tool returning does not end the wait')
  mod.waitAsked(w, 'b')
  mod.waitCallFinished(w, 'a')
  assert.equal(mod.isWaiting(w), true)
  mod.waitCallFinished(w, 'b')
  assert.equal(mod.isWaiting(w), false)
  mod.waitAsked(w, 'c')
  assert.equal(mod.isWaiting(w), false, 'the last dialog does not carry over to the next ask')
  mod.waitDialogOpened(w)
  mod.waitReset(w)
  assert.equal(mod.isWaiting(w), false)
})

test('finding the Mac app, backoff, instance ids', () => {
  assert.equal(mod.appPathFromRoot('/Applications/Design Canvas.app/Contents/Resources/mod'), '/Applications/Design Canvas.app')
  assert.equal(mod.appPathFromRoot('/Users/me/.claude/plugins/cache/design-canvas/0.1.0'), null)
  assert.deepEqual(mod.openAppArgv('/Apps/Design Canvas Dev.app/Contents/Resources/mod'), ['open', '-g', '/Apps/Design Canvas Dev.app'])
  assert.deepEqual(mod.openAppArgv('/elsewhere'), ['open', '-g', '-b', 'com.designcanvas.mac'])
  assert.deepEqual([0, 1, 3, 9].map(mod.backoffTicks), [0, 1, 3, 5])
  assert.match(mod.newInstanceId(), /^dc-[a-z0-9]{24,}$/)
  assert.notEqual(mod.newInstanceId(), mod.newInstanceId())
})

// MARK: - Hooks against a fake `$`

function harness({ daemonUp = true, env = {}, openExit = 0 } = {}) {
  const handlers = []
  mod.register((event, filterOrHook, maybeHook) => {
    const hook = maybeHook ?? filterOrHook
    const filter = maybeHook ? filterOrHook : null
    handlers.push({ event, filter, hook })
  })
  const h = {
    up: daemonUp,
    requests: [],
    queue: [], // rounds the daemon will hand out
    replies: [],
    submitted: [],
    toasts: [],
    ran: [],
    store: new Map(),
    registered: null,
    tickFn: null,
    toolFailures: 0,
    sessionId: 'sid-1',
    releaseSubmit: null,
  }
  const respond = (status, body) => ({ status, ok: status >= 200 && status < 300, headers: {}, text: JSON.stringify(body) })
  const $ = {
    env: { get: async (name) => env[name] },
    plugin: { name: 'designcanvas', root: '/Apps/Design Canvas.app/Contents/Resources/mod' },
    session: { id: async () => h.sessionId, cwd: async () => '/code/acme', repo: async () => ({ root: '/code/acme' }) },
    tool: { register: async (spec) => { if (h.toolFailures > 0) { h.toolFailures -= 1; throw new Error('refused') } h.tool = spec; return { tool: `mcp__designcanvas__${spec.name}` } } },
    store: { get: async (k) => h.store.get(k), set: async (k, v) => { h.store.set(k, v) } },
    ui: { toast: (text) => h.toasts.push(text) },
    // As Claude Code's own: a timer object with cancel(), not a bare function.
    clock: { every: (ms, fn) => { h.tickFn = fn; return { cancel: () => { h.tickFn = null } } } },
    process: { run: async (argv) => { h.ran.push(argv); return argv[0] === 'open' ? { exitCode: openExit, stdout: '', stderr: '' } : { exitCode: 0, stdout: 'main\n', stderr: '' } } },
    prompt: {
      submit: ({ text }) => {
        h.submitted.push(text)
        return new Promise((resolve) => { h.releaseSubmit = () => resolve({ text }) })
      },
    },
    http: {
      fetch: async (url, init = {}) => {
        if (!h.up) throw new Error('ECONNREFUSED')
        const path = new URL(url).pathname
        const method = init.method ?? 'GET'
        const body = init.body ? JSON.parse(init.body) : undefined
        h.requests.push({ method, path, body })
        if (path === '/v1/health') return respond(200, { status: 'ok' })
        if (method === 'POST' && path === '/v1/sessions') { h.registered = body; return respond(200, { target: true }) }
        if (path.endsWith('/poll')) {
          if (!h.registered) return respond(404, { error: 'session_not_found' })
          const next = body.want && body.state === 'idle' ? h.queue.shift() : undefined
          return respond(200, { target: true, ...(next ? { round: next } : {}) })
        }
        if (path.endsWith('/reply')) { h.replies.push({ id: path.split('/')[3], body }); return respond(h.replyStatus ?? 200, {}) }
        return respond(200, {})
      },
    },
  }
  h.fire = async (event, e = {}) => {
    const chain = handlers.filter((x) => x.event === event && (!x.filter || x.filter.tool === e.tool))
    const run = (i) => (i >= chain.length ? (h.core ? h.core(event, e) : {}) : chain[i].hook($, e, () => run(i + 1)))
    return run(0)
  }
  h.tick = async () => { h.tickFn(); await settle() }
  h.pollsWith = (pred) => h.requests.filter((r) => r.path.endsWith('/poll') && pred(r.body))
  return h
}
const settle = async () => { for (let i = 0; i < 30; i += 1) await Promise.resolve(); await new Promise((r) => setImmediate(r)) }

test('start: registers the tool, then the session with the launch nonce and branch', async () => {
  const h = harness({ env: { DESIGN_CANVAS_LAUNCH: 'nonce-1' } })
  await h.fire('classic.SessionStart', { session_title: 'fix header' })
  await h.fire('session.start', { cwd: '/code/acme' })
  assert.equal(h.tool.name, 'reply')
  assert.deepEqual(h.ran.filter((a) => a[0] === 'open'), [], 'daemon reachable: the app is not opened')
  await h.tick()
  assert.equal(h.registered.title, 'fix header', 'the title seen before session.start is kept')
  assert.equal(h.registered.launch, 'nonce-1')
  assert.equal(h.registered.branch, 'main')
  assert.equal(h.registered.repoRoot, '/code/acme')
  assert.match(h.registered.instance, /^dc-/)
  assert.equal(h.pollsWith((b) => b.want === true && b.state === 'idle').length, 1)
  assert.equal(h.store.get('appMissingNotified'), false)
})

test('start with the daemon down: opens the bundled app; says "not installed" once (XG9)', async () => {
  const h = harness({ daemonUp: false })
  await h.fire('session.start', {})
  assert.deepEqual(h.ran.find((a) => a[0] === 'open'), ['open', '-g', '/Apps/Design Canvas.app'])
  assert.deepEqual(h.toasts, [])

  const missing = harness({ daemonUp: false, openExit: 1 })
  await missing.fire('session.start', {})
  assert.deepEqual(missing.toasts, [mod.APP_MISSING_NOTICE])
  await missing.fire('session.start', {})
  assert.equal(missing.toasts.length, 1, 'silent the second time')
})

test('a round: one in flight, served when its turn starts, cleared by the reply', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.queue.push(round(), round({ id: 'second-round-id-0000' }))
  await h.tick()
  assert.equal(h.submitted.length, 1)
  assert.equal(h.submitted[0], mod.promptText(round()))
  await h.tick()
  assert.equal(h.submitted.length, 1, 'nothing more is asked for while one is in flight')
  assert.equal(h.pollsWith((b) => b.want === true).length, 1)

  await h.fire('turn.start', { turnId: 't1', text: `The designcanvas plugin sent a message:\n${h.submitted[0]}` })
  h.releaseSubmit()
  await settle()
  assert.ok(h.requests.some((r) => r.path === `/v1/annotations/${round().meta.id}/served`))
  await h.tick()
  assert.equal(h.pollsWith((b) => b.state === 'busy').length >= 1, true)

  const result = await h.fire('tool.call', { tool: mod.REPLY_TOOL, tool_use_id: 'u1', annotation_id: round().meta.id, status: 'applied', message: 'ok' })
  assert.deepEqual(result, { result: 'Reply recorded.' })
  assert.deepEqual(h.replies, [{ id: round().meta.id, body: { status: 'applied', message: 'ok' } }])
  await h.fire('turn.complete', { turnId: 't1', isAborted: false })
  assert.equal(h.submitted.length, 1, 'no reminder after a reply')
  await h.tick()
  assert.equal(h.submitted.length, 2, 'the next round starts once idle')
  assert.equal(h.pollsWith((b) => typeof b.lastReplyAt === 'string').length >= 1, true)
})

test('no outcome: one reminder, then failed with no_reply (X6)', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.queue.push(round())
  await h.tick()
  await h.fire('turn.start', { turnId: 't1', text: h.submitted[0] })
  h.releaseSubmit()
  await h.fire('turn.complete', { turnId: 'not-ours', isAborted: false })
  assert.equal(h.submitted.length, 1, 'someone else\'s turn ending changes nothing')
  await h.fire('turn.complete', { turnId: 't1', isAborted: false })
  assert.equal(h.submitted[1], mod.reminderText(round().meta.id))
  assert.ok(h.requests.some((r) => r.path.endsWith('/reminded')))
  assert.deepEqual(h.replies, [])
  await h.fire('turn.start', { turnId: 't2', text: h.submitted[1] })
  await h.fire('turn.complete', { turnId: 't2', isAborted: false })
  assert.deepEqual(h.replies, [{ id: round().meta.id, body: { status: 'failed', message: mod.NO_REPLY_MESSAGE, reason: 'no_reply' } }])
  assert.equal(h.submitted.length, 2, 'only one reminder, ever')
})

test('an interrupted turn fails the round with no reminder', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.queue.push(round())
  await h.tick()
  await h.fire('turn.start', { turnId: 't1', text: h.submitted[0] })
  await h.fire('turn.complete', { turnId: 't1', isAborted: true })
  assert.equal(h.replies[0].body.reason, 'interrupted')
  assert.equal(h.submitted.length, 1)
})

test('the reply tool: invalid arguments come back as words; a queued outcome survives a restart', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.queue.push(round())
  await h.tick()
  assert.deepEqual(await h.fire('tool.call', { tool: mod.REPLY_TOOL, annotation_id: 'x', status: 'nope' }), {
    result: 'status must be one of: applied, failed, needs_input.',
  })
  h.up = false
  const result = await h.fire('tool.call', { tool: mod.REPLY_TOOL, annotation_id: round().meta.id, status: 'applied' })
  assert.deepEqual(result, { result: 'Reply recorded.' }, 'Claude is not asked to retry')
  assert.deepEqual(h.replies, [])
  await h.tick()
  h.up = true
  h.registered = null // a new daemon: the poll 404s, the mod registers again
  await h.tick(); await h.tick(); await h.tick()
  assert.equal(h.registered.wasTarget, true, 're-registers as the former target (X9)')
  assert.deepEqual(h.replies, [{ id: round().meta.id, body: { status: 'applied' } }])
})

test('X7: only the composite of the round in flight is approved', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.core = (event) => (event === 'tool.check' ? { decision: 'ask' } : {})
  const path = round().compositePath
  assert.deepEqual(await h.fire('tool.check', { tool: 'Read', tool_use_id: 'r0', input: { file_path: path } }), { decision: 'ask' })
  h.queue.push(round())
  await h.tick()
  assert.equal((await h.fire('tool.check', { tool: 'Read', tool_use_id: 'r1', input: { file_path: path } })).decision, 'allow')
  assert.equal((await h.fire('tool.check', { tool: 'Read', tool_use_id: 'r2', input: { file_path: '/etc/passwd' } })).decision, 'ask')
  assert.equal((await h.fire('tool.check', { tool: 'Bash', tool_use_id: 'r3', input: { command: `cat ${path}` } })).decision, 'ask')
  h.core = (event) => (event === 'tool.check' ? { decision: 'deny' } : {})
  assert.equal((await h.fire('tool.check', { tool: 'Read', tool_use_id: 'r4', input: { file_path: path } })).decision, 'deny')
})

test('X8: waiting is reported at once when a dialog opens, and ends with that call', async () => {
  const h = harness()
  await h.fire('session.start', {})
  await h.tick()
  await h.fire('turn.start', { turnId: 't1', text: 'hello' })
  h.core = (event) => (event === 'tool.check' ? { decision: 'ask' } : {})
  await h.fire('tool.check', { tool: 'Edit', tool_use_id: 'e1', input: { file_path: '/code/acme/a.css' } })
  await settle()
  assert.equal(h.pollsWith((b) => b.state === 'waiting').length, 0, 'asked is not yet waiting (auto mode)')
  await h.fire('classic.PermissionRequest', { tool_name: 'Edit' })
  await settle()
  assert.equal(h.pollsWith((b) => b.state === 'waiting').length, 1, 'posted without waiting for the tick')
  assert.equal(h.pollsWith((b) => b.state === 'waiting')[0].body.want, false)
  await h.fire('tool.call', { tool: 'Grep', tool_use_id: 'g1' })
  await settle()
  assert.equal(h.requests.at(-1).body.state, 'waiting', 'a parallel call finishing does not end it')
  await h.fire('tool.call', { tool: 'Edit', tool_use_id: 'e1' })
  await settle()
  assert.equal(h.requests.at(-1).body.state, 'busy')
})

test('session end: fails the round in flight and deregisters; /clear stays connected', async () => {
  const h = harness()
  await h.fire('session.start', {})
  h.queue.push(round())
  await h.tick()
  await h.fire('session.end', { reason: 'clear' })
  assert.equal(h.replies[0].body.reason, 'session_ended')
  assert.equal(h.requests.some((r) => r.method === 'DELETE'), false)
  assert.notEqual(h.tickFn, null, 'still ticking after /clear')
  h.sessionId = 'sid-2'
  await h.tick()
  assert.equal(h.requests.at(-1).body.sessionId, 'sid-2', 'the new session id is reported')

  h.queue.push(round({ id: 'third-round-id-00000' }))
  await h.tick()
  const repliesBefore = h.replies.length
  await h.fire('session.end', { reason: 'prompt_input_exit' })
  assert.equal(h.requests.at(-1).method, 'DELETE')
  assert.equal(h.replies.length, repliesBefore, 'the daemon closes the rounds on DELETE; one request only')
  assert.equal(h.tickFn, null)
})

test('daemon away: backs off quietly and never throws into the session', async () => {
  const h = harness({ daemonUp: false })
  await h.fire('session.start', {})
  for (let i = 0; i < 12; i += 1) await h.tick()
  h.up = true
  for (let i = 0; i < 6; i += 1) await h.tick()
  assert.notEqual(h.registered, null)
  const title = await h.fire('classic.UserPromptSubmit', { prompt: 'hi' })
  assert.deepEqual(title, {})
})

test('a tool that cannot be registered at start does not leave the session silent', async () => {
  const h = harness()
  h.toolFailures = 2
  await h.fire('session.start', {})
  assert.notEqual(h.tickFn, null, 'the tick runs whatever happened at start')
  await h.tick()
  assert.equal(h.registered, null, 'no tool yet: the session does not offer itself')
  for (let i = 0; i < 6; i += 1) await h.tick()
  assert.equal(h.tool.name, 'reply')
  assert.notEqual(h.registered, null, 'registers once the tool is there')
})

test('the plugin name cannot collide with the old channel entry in .mcp.json', async () => {
  const { readFile } = await import('node:fs/promises')
  const manifest = JSON.parse(await readFile(new URL('../.claude-plugin/plugin.json', import.meta.url), 'utf8'))
  assert.notEqual(manifest.name, 'design-canvas')
  assert.equal(mod.REPLY_TOOL, `mcp__${manifest.name}__reply`)
})
