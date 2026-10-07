# Design Canvas Claude Mods: Technical Specification

**Status:** v0.3, 2026-10-05: Phase 1 is implemented on the `claude-mods` branch; section 13 says what was built, where it differs from the sections above it, and what has and has not been run (v0.2 followed the spike; v0.1 preceded it). Companion to [PRD-ClaudeMods.md](./PRD-ClaudeMods.md) v0.3. Requirement IDs (X), owner decisions (XG) and spike questions (SQ) are shared with that PRD; technical questions raised here are TQ.
**Extends:** [technical_doc.md](./technical_doc.md) v0.5 and [technical_doc-BlankCanvas.md](./technical_doc-BlankCanvas.md) v0.2. Those documents own the engine, the store, the wire and the round up to the moment it is stored. This one specifies only the hop between the daemon and Claude Code, and what that hop adds to the two apps. It covers Phase 1; Phase 2 gets one section of notes.
**How each API fact is known.** *Run*: observed in the spike of 2026-10-05 (section 10) or the earlier throwaway mod, on Claude Code v2.1.289. *Declared*: in the type declarations that version writes beside a mod. *Docs*: the mods pages read 2026-10-04. What is still not *run* is listed in section 12.

## 1. Shape of the change

Today Claude Code spawns `designtool --channel`, which holds the daemon's event stream open, claims each round, and pushes it in as a channel notification. That process is replaced by a mod: one JavaScript module that Claude Code loads into the session. The mod cannot hold a stream open (`$.http.fetch` returns only a complete answer, and gives up after 30 s, *run*), so it polls the daemon; in exchange it sees turns, tool calls and the session's end, which the channel never could.

```
iPad ── annotation ──▶ Mac engine ── POST /v1/annotations ──▶ daemon (store, session registry, target)
                                                                ▲                │
                                              poll, 1 Hz        │                │ round (claimed)
                                              state, outcome    │                ▼
                                   ┌────────────────────────────┴──────────────────────────────┐
                                   │ Claude Code session                                       │
                                   │  design-canvas mod                                        │
                                   │   session.start  register, open the Mac app if needed     │
                                   │   clock tick     poll; when idle, claim the next round    │
                                   │   prompt.submit  one round, one turn                      │
                                   │   tool: reply    Claude's outcome, posted to the daemon   │
                                   │   tool.check     allow the read of this round's composite │
                                   │   turn.complete  no outcome: remind once, then failed     │
                                   │   session.end    fail the round in flight, deregister     │
                                   └───────────────────────────────────────────────────────────┘
iPad ◀── agentReply, rounds, sessions ── Mac engine ◀── rounds stream, sessions stream ── daemon
```

What does not change: capture, the frame ring, compositing, `UploadPipeline`, `POST /v1/captures` and `POST /v1/annotations`, the store layout, the reply endpoint, the rounds list, `agentReply`, and the Draw Mode state machine. A round is stored exactly as today; the difference starts at who claims it.

What goes away, at rollout step 3: `server/src/channel/`, the `--channel` run mode, the MCP SDK dependency, `McpConfigManager`, and the `--dangerously-load-development-channels` flag.

The spike ran this shape end to end with a prototype mod against the existing daemon and its existing claim, served and reply endpoints: 19 sketches delivered, one per turn; 18 ended in Claude's own outcome and one was interrupted on purpose (section 10).

| Requirement | Section |
|---|---|
| X1, X2, X10 | 6.1 |
| X3, X4 | 4.1 |
| X5 | 4.2, 7 |
| X6 | 4.3 |
| X7 | 4.4 |
| X8 | 4.5, 5 |
| X9 | 3.2, 6.2 |
| X11 | 3.4 |
| X18, X19 | 2.3 |
| X20 | 6.3 |
| X21 to X26 | 3.3, 5, 6.2, 7 |

## 2. The mod

### 2.1 Package

A plugin named `design-canvas`, in a new `DesignCanvas/mod/` directory:

```
mod/
  .claude-plugin/plugin.json     name, version, description, author
  hooks/hooks.json               { "modules": ["./register.js"] }
  hooks/register.js              export function register(on) { ... }
```

The hooks module is plain JavaScript with no build step and no dependencies. Node APIs are not available inside it (*docs*); everything it does goes through the `$` argument. Logic that needs no `$` (the prompt text, argument parsing, the round state machine) is written as pure functions in the same file so the server's test runner can import and test them.

`claude plugin validate` runs a static analysis that the code must be written for (*run*): `$` has to appear as `$.noun.method(...)` at each call site. Passing `$` to a helper function is accepted and reported (`$.fs.write (via log)`); reading a whole namespace, such as `JSON.stringify($.plugin)`, fails validation. CI runs `claude plugin validate --strict` on the directory.

A post-build step beside `tools/bundle-server.sh` copies the directory to `Design Canvas.app/Contents/Resources/mod/`. That copy is what both ways in load (X1, XG7).

### 2.2 What it uses

This is the list `claude plugin validate` prints for it, and the list the PRD's risk table promises to publish.

| Event or call | Used for | Known by |
|---|---|---|
| `session.start` | Register the tool, register with the daemon, start the tick. `e` is `{cwd, surface, isInteractive}` | *run* |
| `session.end` | Fail the round in flight, deregister. All `session.end` hooks share 1.5 s (*docs*) | *run* |
| `turn.start`, `turn.complete` | Track busy and idle; find the round's own turn; detect a turn that ended with no outcome | *run* |
| `tool.call` filtered to `mcp__design-canvas__reply` | Answer the reply tool | *run* |
| `tool.call` unfiltered, `tool.check`, `classic.PermissionRequest` | Waiting state (4.5) | *run* |
| `tool.check` filtered to `Read` | X7 (4.4) | *run* |
| `classic.SessionStart`, `classic.UserPromptSubmit` | Read `session_title` (X25) | *run* |
| `$.tool.register` | The reply tool | *run* |
| `$.prompt.submit` | Start a turn for a round; the one reminder | *run* |
| `$.clock.every` | The 1 s tick. It keeps firing during a turn | *run* |
| `$.http.fetch` | Every daemon call, loopback only. Passes the daemon's local-request guard | *run* |
| `$.process.run` | `open` the Mac app; `git branch --show-current` | *run* (`open`) |
| `$.session.id`, `$.session.cwd`, `$.session.repo` | Registration. `repo()` gives `{root, remote, name, internal}` | *run* |
| `$.env.get` | The launch nonce (6.1) and `SERVER_PORT` | *run* |
| `$.plugin.root` | Find the app the mod is bundled in | *run* |
| `$.store` | The "app not installed" notice flag (XG9) | *docs* |
| `$.ui.toast` | The X19 notice, and nothing else | *docs* |

v0.1 named `$.ui.notice` for the X19 notice. The declarations show that call attaches a line to an open tool dialog and takes a `tool_use_id`, so it cannot carry a notice at session start; `$.ui.toast` can.

Not used, by the PRD's guardrails: `$.model.*` (no model call), any pane, command or status line (no interface inside Claude Code), and `$.fs` (the mod never touches the user's project).

### 2.3 Session start (X18, X19)

`session.start` fires once per loaded mod before the first prompt, and Claude Code waits for it (*docs*), so the tool is registered before any turn.

1. `$.tool.register` the reply tool (4.2).
2. Make an instance id (random, kept in module scope). The registry is keyed on it and not on the Claude Code session id. *Run*: `/clear` ends the session (`session.end` with reason `clear`) and `$.session.id()` returns a new id afterwards, while the module, its variables and its timer carry on and `session.start` does not fire again. A registry keyed on the session id would lose the session at every `/clear`.
3. `GET /v1/health`. If it answers, go to 5.
4. If it does not, open the Mac app, then go to 5 anyway. The app path comes from `$.plugin.root` when that lies inside an `.app` bundle (`open -g <app path>`), else from the bundle id (`open -g -b com.designcanvas.mac`). `-g` keeps the terminal in front. *Run*: `open -g -b` exits 0 for an installed app and 1 for an unknown bundle id. On exit 1 the mod shows the X19 notice once: it sets `appMissingNotified` in `$.store`, which every session on the machine shares, and stays silent while that is set. The flag is cleared the next time any session reaches the daemon (XG9).
5. Start `$.clock.every(1000, tick)`. The first successful tick registers. The mod never blocks on the app coming up; the PRD's 5 s target is the app's launch time plus at most one tick.

The app is opened only here. If the user quits the app during a session, the tick backs off (1 s to 5 s) and stays silent until the daemon is back; it does not reopen an app the user just closed.

**Whose permission the opened app runs under (SQ4).** macOS ties a privacy grant to the process it holds responsible. *Run*: an app the mod opened with `open -g -b` was its own responsible process and had launchd as its parent, while a plain child the mod spawned in the same hook was attributed to the terminal app. The running Design Canvas Dev app, started from Xcode, is likewise its own responsible process. So an app opened by the mod stands toward Screen Recording as one opened from Finder. The literal check, Design Canvas capturing after a mod opened it, was not run: the only signed build on the machine was in use in a live session (section 12).

### 2.4 The tick

One `POST /v1/sessions/<instance>/poll` per second, carrying the session's current state. The reply says whether this session is the target and, when the mod asked for one and one is due, carries the next round already claimed for this session.

```
state            idle | busy | waiting
want             true when state is idle and no round is in flight
sessionId        $.session.id(), re-read each tick
branch           refreshed at turn.complete
title            from classic.SessionStart and classic.UserPromptSubmit
lastReplyAt      time of the last turn.complete of the main agent
```

A 404 means the daemon does not know the instance (it restarted, which is what an app relaunch does): the mod re-registers with `POST /v1/sessions` and carries `wasTarget` from the last reply it saw, so a relaunch does not move the target (X9). A state change posts at once and does not wait for the tick, which is what keeps X8 under its 2 s target.

**Title (SQ5, *run*).** `session_title` arrives on `classic.SessionStart` and on every `classic.UserPromptSubmit` when the session has a name (started with `claude --name`). A session nobody named carries no title on either event, through several turns. So the title is real but is the exception; X25's fallback to the start time is what most rows will show.

**Why not a long poll (TQ4, *run*).** `$.http.fetch` returned a 20 s response and rejected 45 s and 90 s ones at exactly 30 s ("no complete answer within 30000ms"). A long poll of up to about 25 s is therefore possible. It is not adopted: 1 Hz on loopback is cheap, needs no timeout tuning, and doubles as the heartbeat. It stays available if idle traffic ever matters.

## 3. Daemon

### 3.1 Endpoints

All loopback, behind the existing `requireLocalRequest` guard, which the mod's requests pass (*run*).

| Endpoint | Caller | Does |
|---|---|---|
| `POST /v1/sessions` | mod | Register or re-register. Body: `instance`, `sessionId`, `cwd`, `repoRoot?`, `branch?`, `title?`, `startedAt`, `modVersion`, `launch?`, `wasTarget?`. Returns `{target}` |
| `POST /v1/sessions/<instance>/poll` | mod | Heartbeat and state (2.4). Returns `{target, round?}`; `round` is `{meta, compositePath, capturedAt}`, the shape `/claim` returns today. 404 for an unknown instance |
| `DELETE /v1/sessions/<instance>` | mod | Session ended |
| `GET /v1/sessions`, `GET /v1/sessions/stream` | Mac app | The list and the target; the stream is SSE, like the rounds stream |
| `PUT /v1/sessions/target` | Mac app | `{instance}`: switch the target (X24) |
| `POST /v1/annotations/<id>/served` | mod | Existing. Called when the round's turn has started |
| `POST /v1/annotations/<id>/reminded` | mod | New. Records `remindedAt` and logs it |
| `POST /v1/annotations/<id>/reply` | mod | Existing, with one additive optional field `reason` (4.3) |

`POST /v1/annotations` gains an optional `session` in its `meta` part (the instance the round is bound to, section 5). `/v1/health` keeps `channelCount` while the channel exists and gains `sessionCount`.

`/v1/annotations/<id>/claim` and the annotation stream stay until the channel is removed. A round bound to a session is refused to the channel's claim, and a channel is never a session, so the two cannot both deliver one round. The spike's prototype used `GET /v1/annotations` plus `/claim` in place of `poll`, which is why it needed no daemon change; `poll` folds those two calls and the heartbeat into one.

### 3.2 Session registry

In memory only. Nothing about a session is written to disk, which is the whole of X9's "recognised after relaunch": the daemon is the app's child and restarts with it, every live mod gets a 404 on its next tick and re-registers within a second, and a session started by hand with the mod loaded registers the same way as one the app launched.

- A session whose last poll is older than 15 s is removed, as if it had sent `DELETE`. This covers a killed terminal.
- For 5 s after the daemon starts, nothing is failed and no default target is chosen, so sessions that are about to re-register are not mistaken for dead ones.
- `launch` is the nonce the Mac app put in the session's environment (6.1); the mod reads it with `$.env.get` (*run*). It replaces ADR-0004's "owned only if this app run launched it while the count was 0" with a statement the session makes about itself.

There is no authentication on any of this, as on the rest of the loopback API. A local process can register as a session and be handed sketches; it can already read them from `GET /v1/annotations`. Unchanged by this design and recorded in the PRD's risk table.

### 3.3 Target (X21, X22, X26)

The daemon owns the target, because both the Mac app and every mod need the same answer and the daemon is the one process they all talk to.

- One session: it is the target.
- No target and several sessions, which in practice is the settle window after a daemon restart: a session that carries a `launch` nonce (one the Mac app started), else the one with the latest `startedAt`. While the window is open this default is revised as sessions come back, since the order they re-register in means nothing; once it closes the target is sticky. A re-registration with `wasTarget` wins over both and is not revised.
- A target, and another session registers: nothing changes (sticky).
- The target ends: one session left becomes the target; several left means no target, and the list says so (`target` absent), which is the state where both apps ask the user to pick.

### 3.4 Store and log (X11)

`meta.json` gains three additive fields on schema 3, so no migration and old records read as before:

| Field | Meaning |
|---|---|
| `session?: {instance, sessionId, folder}` | The session the round is bound to. Absent: not bound yet |
| `remindedAt?` | When the one reminder was sent |
| `reply.reason?` | `no_reply`, `session_ended` or `interrupted` when the mod, not Claude, wrote the outcome. Absent for Claude's own reply |

`reply.reason` is what rollout step 3 counts ("X6's no-reply failure rate") and what keeps a round Claude failed apart from one nobody answered.

The claim lease changes for a session's claim. The channel's 30 s lease assumed the claimer emits at once. The mod submits a prompt that waits for the session to be idle; in the spike a prompt submitted during a turn waited 20 s for it. A session's claim therefore holds for as long as that session is registered, and the sweep returns it to pending only when the session is gone.

New log events, in the existing JSON-lines log: `session.registered`, `session.ended` (with `cause`: `deregistered` or `stale`), `session.state`, `target.changed` (with `by`: `default`, `mac`, `ipad`), `round.claimed`, `round.served`, `round.reminded`, `round.failed` (with `reason`). The poll itself is logged only when it changes something, like the health probe today; at 1 Hz per session it would otherwise be the log.

## 4. A round, from claim to outcome

```
                 poll returns it            turn starts               reply tool
   pending ─────────────────────▶ serving ─────────────▶ served ───────────────────▶ applied | failed | needs_input
   (queued on iPad)               (queued)               (sent)
                                                           │ its turn ends, no outcome
                                                           ▼
                                                        reminded ── that turn ends, no outcome ──▶ failed (no_reply)
   any state before an outcome, session gone ──────────────────────────────────────────────────▶ failed (session_ended)
```

### 4.1 Delivery (X3, X4)

The mod holds at most one round in flight. On a tick with `want`, the daemon hands over the oldest pending round bound to this session, or, if this session is the target, the oldest unbound one, which it binds. The mod then calls `$.prompt.submit({ text })` and, when that resolves, posts `served`, and the iPad moves the round from queued to sent.

*Run*: `$.prompt.submit` called while the session was idle resolved in 0.2 s with the turn started. Called while a turn was running, it waited for that turn to end and resolved 20 s later as its own turn began. So a prompt the user types between the claim and the submit only delays the round; nothing is lost and nothing is merged. The call is made from the tick's own async chain, never awaited inside a hook that runs during a turn (*docs*).

One round per turn follows from one round in flight: the next `want` is not sent until the current round has an outcome. That settles G10 by construction, where the channel delivered whatever had queued up in one turn. *Run*: three sketches posted within four seconds were delivered in three consecutive turns, in order. A round a session claimed is that session's: if the session dies before the turn starts, the round is failed with its other rounds (X26), not handed to someone else. A round that no session has claimed yet stays pending for the next target, as D5 requires.

The prompt text is the channel's notification text with the tool renamed, so the reply-compliance eval compares like with like:

```
New annotation from iPad.
Annotation ID: <uuid v7>
Device: <iPad name>
Captured at: <iso>
Sent at: <iso>
Composite PNG path: <absolute path>
Zoom region: <normalized rect, or "full frame">
Note: <text or "(none)">

Inspect the composite PNG path to see the visual annotation.
Apply this annotation to the source code, then call mcp__design-canvas__reply exactly once with the outcome.
```

The blank-canvas variant changes the same way. The channel's server `instructions` have no equivalent that is scoped to our rounds (a `prompt.context` block would be read in every session, including unrelated projects under the opt-in), so their content moves into the prompt's last line and the tool's description.

**Framing and compliance (SQ2, *run*).** Claude receives the text as `The design-canvas plugin sent a message:` followed by the prompt. With that framing, 10 of 10 rounds in the spike's eval run were answered with the reply tool on the first turn, with no reminder, and all ten edits were correct. `asUser: true`, held in reserve in v0.1, is not needed and is not used.

**The sketch is a file path (SQ3, *declared*).** `$.prompt.submit` takes text only. Its attachment type records "its kind, never its bytes", and pasted images are "not expanded for a plugin's prompt, `asUser` or not". Claude read the composite with the Read tool in every spike round (G23 unchanged).

### 4.2 Outcome (X5)

`$.tool.register({ name: 'reply', ... })` with the schema and description of today's `design_canvas_reply`. Claude sees it as `mcp__design-canvas__reply` (*run*). The `tool.call` hook filtered to that name receives the arguments as fields of `e`, validates them with the logic of `reply-tool.ts` (ported, with its tests), posts to `/v1/annotations/<id>/reply`, and returns the same texts as today: "Reply recorded.", "A reply was already recorded for this annotation.", "Unknown annotation id.". The daemon stores the reply and emits the round; the engine forwards `agentReply`. Nothing downstream changes.

**No permission prompt for the reply tool (TQ2, *run*).** The hook answers the call itself and never calls `next`, so the call never reaches Claude Code's permission decision: no `tool.check` and no permission request were raised for it, in default mode or in auto mode. The PRD's guardrail keeps its single exception.

If the post fails because the daemon is down (an app relaunch mid-round), the mod keeps the outcome and posts it on the next tick that succeeds, and tells Claude it was recorded. A real outcome is not lost to a restart.

The "head of the message" half of X5 is an iPad rendering change (section 7). The wire still carries up to 2 KB and the store keeps the full text. Replies in the spike ran 87 to 140 characters.

### 4.3 No outcome (X6)

The mod has to know which turn is the round's. It is the `turn.start` whose `text` contains the round's annotation id; its `turnId` is kept with the round. This matters because other turns run in the same session and end without touching the round: a prompt the user typed, and, seen in the spike, a turn Claude Code starts by itself for a background task's notification. Only the `turn.complete` carrying the round's `turnId` (or the reminder's) is judged.

| The round's turn ended | Reminded already | The mod does |
|---|---|---|
| Normally | No | Posts `reminded`, then `$.prompt.submit` with: "You have not reported an outcome for Design Canvas annotation `<id>`. Call mcp__design-canvas__reply now with applied, failed or needs_input." |
| Normally | Yes | Posts the reply `failed`, message "Claude did not reply to this sketch.", `reason: no_reply` |
| Interrupted (`e.isAborted`) | Either | Posts `failed`, message "Stopped at the Mac before Claude replied.", `reason: interrupted`. No reminder |

*Run*: a round whose note told Claude not to reply ended its turn with no outcome; the reminder started a second turn, and Claude called the reply tool in it. A turn stopped with Esc arrived as `turn.complete` with `isAborted: true`.

The interrupted row is X6's second sentence (owner decision, 2026-10-05). A reminder would start a turn the user just stopped by hand, so the round is closed at once.

At `session.end` with `e.reason` of `clear` or `resume` the process lives on, so the mod posts `failed` with `reason: session_ended` for the round in flight and stays registered. For any other reason it sends one request, the `DELETE` of its registration, and the daemon fails that session's unanswered rounds, in flight and queued alike. One request, because every `session.end` hook on the machine shares 1.5 s. If the mod never gets to run (`kill -9`), the daemon's 15 s staleness does the same for the round in flight and for every round still queued for that session (X26).

A late genuine reply to a round already marked failed gets the existing 409 and "A reply was already recorded". A failed round frees the mod's one slot, so the next round is claimed on the next tick (X4).

**When `turn.complete` arrives.** In every spike turn it came 8 to 10 s after Claude's answer was on screen. The terminal showed "running Stop hooks" in that gap, and this machine has five. The gap delays the next queued round and the X6 check by that much. It is the user's own configuration, not something the mod can shorten, and a round's own outcome is not affected: the reply tool is called before the answer ends.

### 4.4 Reading the sketch without a prompt (X7)

*Run*: a Read of the composite, which lives outside the project, resolves to `ask` in `tool.check`, in default mode and in auto mode, and in default mode a permission dialog opens. D22's first assumption, that reading the store path never prompts, was wrong. X7 is needed.

A `tool.check` hook filtered to `Read`. It calls `next(e)` first and returns that decision unchanged unless all of these hold: the decision is `ask`, a round is in flight, and `e.input.file_path` is exactly, as a string, the `compositePath` the daemon handed over for that round. Then it returns `{ decision: 'allow' }`. *Run*: with the hook, the read went through with no dialog in every round where it was switched on, including all ten of the eval run; reads of project files were untouched.

Exact equality with one known path is deliberately narrower than the PRD's "one resolved directory": there is no path arithmetic to get wrong, no symlink to follow, and nothing is allowed when no round is in flight. A `deny` is never touched, and on a managed machine a user's mod cannot override a deny rule in any case (*docs*).

### 4.5 Waiting at the Mac (X8)

The session's state is one of `idle`, `busy` (between `turn.start` and `turn.complete`), `waiting`.

*Run*, default mode: when a call needs the user, `tool.check` resolves to `ask` and `classic.PermissionRequest` fires in the same 10 ms, as the dialog opens. The call's `tool.call` hook, which wraps the whole call, resolves when the user has answered and the tool has run (8 s later in the spike, the scripted delay before approving). *Run*, auto mode: `tool.check` still resolves to `ask`, but no `classic.PermissionRequest` fires and no dialog opens, because the mode's classifier answers. So `ask` alone must not be read as waiting; v0.1's fallback is dropped.

The rule:

1. `tool.check` resolving to `ask` records that call's `tool_use_id` as *asked*.
2. `classic.PermissionRequest` enters `waiting`. (It carries the tool's name and input but no call id, which is why step 1 exists.)
3. When the unfiltered `tool.call` hook's `next(e)` resolves for an asked id, the id is dropped. `waiting` ends when no asked id is left, and in any case at `turn.complete` and `session.end`.

Step 3 is per call because Claude runs tools in parallel. The spike's first prototype ended `waiting` when any call finished, and a second tool returning cleared the state while the dialog for the first was still open.

Each change is posted at once. The daemon passes it to the Mac app on the sessions stream and the engine sends it to the iPad (section 5). Nothing about the tool or the command leaves the session: the mod posts the word `waiting` and no more (XG6).

`classic.Notification` with `notification_type: permission_prompt` also fires, but 6 s after the dialog opens, so it is not used.

## 5. Wire additions

Additive JSON control messages, no `pv` bump, under the existing `welcome.canvas` gate. Normative text belongs in `PROTOCOL.md` section 11 when built.

| Message | Direction | Fields | Purpose |
|---|---|---|---|
| `sessions` | Mac to iPad | `sessions[]` of `{id, folder, title?, branch?, startedAt, lastReplyAt?, state}`, `target?` | The connected sessions and which one is the target. Sent after every `hello` and on every change (X8, X24, X25) |
| `selectSession` | iPad to Mac | `id`, `t` | The iPad's choice of target (X24). The Mac answers with a fresh `sessions` |
| `annotation.session` | iPad to Mac | `id` | The target the iPad was showing when Done was tapped (X23) |

The PRD's dependency table counts one message for X8 and two for the session list. `sessions` carries both, because "waiting" is a property of a session and the iPad needs the list anyway; the count is three additions either way.

- **Size.** `sessions` obeys the 32768-byte rule (D23): at most 20 entries, `title` and `branch` cut to 80 characters, `folder` to 60.
- **Binding (X23).** The engine passes `annotation.session` through in the upload's meta, and the daemon stamps `meta.session` from it when that session is still connected. An upload with no `session` (an older iPad) is stamped by the daemon with the target at the moment it arrives. An annotation naming a session that has since ended is stored and failed at once with `session_ended`, so the iPad shows an outcome instead of a round that never moves. A resend after a link loss carries the same `session`, since the pending annotation's bytes are kept.
- **No target (X26).** `sessions` with several entries and no `target` disables Done on the iPad until one is picked. An older iPad still sends; the round is stored unbound and goes to whichever session becomes the target.
- **`ping`.** `channel` keeps its values for older iPads: `attached` when a target exists, `detached` when the daemon is up with no session, `none` as today. `existing` is no longer sent, because X9 removes the state it named. `project` is the target's folder name.

| iPad | Mac | Result |
|---|---|---|
| new | new | Switcher, waiting state, binding at Done |
| new | old | No `sessions` ever arrives; the iPad behaves as today |
| old | new | `sessions` ignored; rounds go to the target at arrival; no waiting state (X10) |

## 6. Mac app

### 6.1 Start session (X1, X2, X10)

`ClaudeLauncher.shellCommand` becomes:

```
cd '<repo>' && DESIGN_CANVAS_LAUNCH=<nonce> claude --plugin-dir '<app>/Contents/Resources/mod'
```

- The flag is passed whether or not the opt-in (6.3) is on. *Run*: with the same directory named both in `CLAUDE_CODE_PLUGIN_DIRS` and in `--plugin-dir`, the mod loaded once. X1's "not a second time" is Claude Code's own behaviour and needs no branch in the launcher. This holds while both name the same directory; a marketplace copy alongside the bundled one is a different case, deferred with the listing.
- `startSession` no longer calls `McpConfigManager`. Nothing is written to the project, and an old `design-canvas` entry in `.mcp.json` is neither read nor changed (X2, XG5). Settings loses its "Project configuration" section.
- Before launching, the app runs `claude --version` through the login shell, the way it already resolves `node`. Missing: "Claude Code was not found." Older than 2.1.287: "Claude Code `<version>` is too old for Design Canvas. Update it with `claude update`, then start the session again." The minimum is one constant, raised when the mod starts using something newer.
- A project folder Claude Code has not seen before opens on its trust question, whose default answer is "No, exit" (*run*). No mod loads until the user answers yes there. This is the first thing a new user sees after Start session and the launch-pending copy should say so.
- An organisation's block cannot be detected up front from outside Claude Code: `disableSideloadFlags` makes `claude --plugin-dir` exit with its own message in the terminal, and `allowManagedModsOnly` lets Claude Code start with the mod refused (*docs*). Both look the same to the app: no session registers. The existing 60 s launch timer covers it, and its message names the causes in plain words and points at the terminal.

### 6.2 Session state (X9, X21 to X26)

`AppModel` subscribes to `/v1/sessions/stream` through `DaemonClient`, as it does for rounds, and stops deriving a channel from `/v1/health`.

- `SessionStateClassifier` keeps its daemon axis unchanged (owned, foreign, unknown occupant, none); a foreign daemon is still a real state. Its channel axis shrinks to: no session, launch pending, connected. `ownedAttached` and `existingSessionDetected` merge, because who started a session no longer decides whether it can be used. `sessionStarted` and the pinned-instance bookkeeping for channel ownership go.
- The launch nonce is kept in `UserDefaults`, so after an app relaunch the session the app started is still recognisable as the X22 default.
- The menu lists connected sessions with a tick on the target and sends `PUT /v1/sessions/target` on a click. One session: no list (X21). Several with no target: the row asks the user to pick.
- The project picker and Recent projects stay, and feed only Start session (XG8).
- Reset stops Design Canvas's own helper processes, as today, and still never kills Claude Code.

### 6.3 The opt-in (X20, XG7)

Asked once, on first launch, in a sheet that states the two consequences from X20. The answer is stored in `UserDefaults`; Settings has the same switch.

Turning it on adds the bundled mod's absolute path to `CLAUDE_CODE_PLUGIN_DIRS` under `env` in `~/.claude/settings.json`. That variable is documented for exactly this: "plugin directories to load as `--plugin-dir` does, for apps you can't pass a flag to" (*docs*). It is chosen over a local-directory marketplace entry because it is one value with one obvious undo.

*Run* (TQ5): a session started with plain `claude` loaded the mod when the variable was set in the shell, and when it was set under `env` in a settings file passed with `--settings`. A session with neither did not load it. The user's own `~/.claude/settings.json` was not edited for the spike, so the last link, that file's `env` block, rests on the docs and on the `--settings` run.

- The file is the user's. A new `ClaudeSettingsManager` carries over `McpConfigManager`'s rules: read, change one key, write atomically, keep every other key, and never rewrite a file that does not parse (the switch then reports the problem and stays off).
- The value is a `:`-separated list. Only our path is added or removed; other entries are kept in order.
- At each launch with the opt-in on, the app checks that the path in settings is its current bundle path and rewrites it if the app was moved (XG7's self-repair). The path it last wrote is remembered so the old one can be removed.
- Turning it off removes that path, and removes the variable if nothing else is in it. That is all turning it on added (X20).
- A Debug build registers nothing unless asked: two different directories holding a mod of one name is not a state worth supporting.

When the marketplace listing exists, the same switch writes `enabledPlugins` for the listed plugin instead and removes the path. An installed plugin is a cached copy outside the app, which is why 2.3 falls back to the bundle id to find the app.

## 7. iPad

- **Connection status (X24, X25).** `CanvasModel` holds the last `sessions` message. With more than one session the project name in `ConnectionStatusView` becomes a button that lists them: folder, title or start time, branch, time of last reply, a tick on the target. A tap sends `selectSession`. The list is not shown in Draw Mode, like the surface control, so the target cannot change under a sketch.
- **Done (X23, X26).** `done` stamps the shown target's id into the pending annotation. With several sessions and no target, Done is disabled and the status asks for a pick.
- **Waiting (X8).** When the target's `state` is `waiting`, the status panel shows "Waiting at the Mac", and so does the newest of this device's rounds that has no outcome. No other text.
- **Head of the message (X5).** `AgentRepliesView` limits the message to two lines with a trailing ellipsis. Today it is `Text(message)` with no limit.
- `sessions` is cleared on a new connection and on a link drop, like `macSupportsBlank`.

## 8. Failure modes

| Case | Behaviour |
|---|---|
| Mac app quit during a session | Ticks fail and back off to 5 s, silently. Rounds cannot arrive anyway (the app is the iPad's only link). On relaunch the session re-registers and keeps the target |
| Daemon restarts mid-round | The mod keeps the round in flight and its outcome, and posts on the next good tick |
| Terminal closed or Claude Code killed | `session.end` if it runs (*run*: it fired on SIGTERM and on `/exit`), else 15 s staleness: the round in flight and the session's queued rounds are failed with `session_ended` |
| `/clear` or `/resume` mid-round | The round is failed; the session stays registered under the same instance with its new session id (*run* for `/clear`) |
| The user types while a round waits for its turn | `$.prompt.submit` waits for idle (*run*); the round shows queued for as long as that takes. The claim does not expire (3.4) |
| A turn that is not the round's ends | Ignored: only the round's `turnId` is judged (4.3) |
| Claude calls the reply tool twice | 409, "A reply was already recorded", as today |
| Claude replies after the round was failed for no reply | Same 409. The iPad keeps showing failed |
| Claude replies with an id that is not the round in flight | Accepted if the round exists and has no reply: the store, not the mod, is the authority |
| Two sessions, same folder | Two registry entries, told apart by title, branch and times (X25) |
| Same mod directory named twice | Loaded once (*run*) |
| The mod's hook throws | Claude Code skips a hook that fails before `next` and the session carries on (*docs*). Every hook body is wrapped so a daemon error never becomes a tool-call failure for the user |
| Workspace not trusted yet | No mod loads until the trust question is answered yes (*run*); the session registers after that |
| Subagent turns | Ignored for outcome tracking (`e.agentId` set); their permission prompts still count as waiting |
| Many Stop hooks on the machine | `turn.complete` trails the answer by their run time; the next queued round waits that long (4.3) |

## 9. Tests

Hostless, in the existing targets.

- **Server.** Registry: register, re-register with `wasTarget`, staleness, the settle window. Target: each rule of 3.3. Poll: hands out bound rounds in order, binds an unbound round to the target only, hands out nothing without `want`. Session claims do not expire while the session lives and do when it goes. `reminded`, and `reply.reason` validation. A bound round is refused to the channel's claim. Rounds bound to an ended session are failed.
- **Mod.** The pure functions under the server's runner: prompt text for both bases, argument parsing (the ported `reply-tool` cases), the round state machine of section 4 driven by a scripted sequence of events, including a foreign turn, an interrupt and a session end. The hooks themselves against a fake `$` that records calls: one round in flight, no reminder after an abort, the X7 rule (allow on exact match only, never over a deny, never with no round in flight), the waiting rule with two parallel calls. `claude plugin validate --strict` in CI.
- **Mac.** `ClaudeLauncherTests`: the command, quoting, the nonce. `ClaudeSettingsManagerTests`: add, remove, move, other entries kept, malformed file untouched. `SessionStateClassifierTests` rewritten for the two-state channel axis. `CanvasMessagesTests`: `sessions` round-trip, size cap, `selectSession`, `annotation.session`. `CanvasSessionTests`: binding rules of section 5.
- **iPad logic.** `CanvasModelTests`: Done stamps the target; Done is blocked with no target; `sessions` cleared on link loss.
- **End to end.** `server/scripts/e2e-round.mjs` gains a mod path, built from the spike's harness: a scratch daemon on its own port and store, a script that posts a capture and an annotation as JSON, and a real `claude --plugin-dir` session driven through a pty. The [reply-compliance eval](./reply-compliance-eval.md) runs once on the channel as the baseline, then on the mod with a real iPad.

## 10. Spike results

Run 2026-10-05 on Claude Code v2.1.289, macOS, by the document's author (Claude Code, in the owner's session). A prototype mod (about 110 lines) ran in real interactive sessions against a scratch daemon on port 47199 with its own store, so the owner's live session on 47100 was not touched. Sketches were synthetic: a drawn mock of a small HTML and CSS page with a red circle on the target, plus a note, posted to the daemon as JSON. No iPad and no Mac app took part. The prototype, its logs and the scratch project were in a session scratch directory and are not kept.

| Run | Setup | What it showed |
|---|---|---|
| A | Sonnet 5.5, auto mode, 3 sketches | The whole loop; queueing; the reminder; timers during turns; the 30 s fetch limit |
| B | Sonnet 5.5, default mode, named session, 2 sketches, dialogs approved after 8 s | Permission signals; no prompt for the reply tool; session title |
| C | Opus 5.5, auto mode, 10 sketches 45 s apart | Reply compliance |
| D | Sonnet 5.5, auto mode, no idle gating, Esc, `/clear`, `/exit` | Submit while busy; interrupt; `/clear`; clean exit |
| E | Haiku 4.5, `claude -p`, a second small mod | Loading from `CLAUDE_CODE_PLUGIN_DIRS`; responsibility of an opened app |

| Question | Answer | Evidence |
|---|---|---|
| SQ2. Reply compliance with a mod's prompt | Holds. 10 of 10 replied on the first turn, no reminder; all ten edits correct; reply 6 to 11 s after the turn started. The eval's threshold is 9 of 10 | Run C. The channel baseline was not rerun (section 12) |
| SQ3. Image in the prompt | No. Text only; the sketch stays a file path | Declarations; every round read the path |
| SQ4. Opening the Mac app; Screen Recording | An app the mod opens is its own responsible process, as when opened from Finder. Capture by Design Canvas after such a launch not run | Run E, with a responsibility probe |
| SQ5. Session title | Delivered for a named session, on session start and on each prompt. Absent for an unnamed one | Runs A and B |
| TQ1. Waiting signal | `classic.PermissionRequest` at the dialog; the wrapping `tool.call` at its end, tracked per call. Not `tool.check` alone | Runs A and B |
| TQ2. Does the reply tool prompt | No, in default or auto mode | Runs A and B |
| TQ3. Timers and submit during a turn | The tick keeps its 1 Hz; a submit during a turn waits and starts its own turn | Runs A and D |
| TQ4. Long fetch | 20 s fine; cut off at 30 s | Run A |
| TQ5. `CLAUDE_CODE_PLUGIN_DIRS` | Loads from the shell and from a settings `env` block; a directory named twice loads once | Run E |

Also found, and folded into the design above: reading the composite does prompt without X7 (4.4); the validator's rule on `$` (2.1); `$.ui.notice` is the wrong call for X19 (2.2); turns the round does not own (4.3); the Stop-hook gap (4.3); the trust question's default (6.1); `/clear` changes the session id (2.3).

Limits of the run. Nineteen sketches is a smoke test, not a rate: it shows the mod path is not worse than the eval's bar, not what the long-run failure rate is. The sketches were clean mocks on a twelve-line page, easier than a real screen. Run C used auto mode, the owner's default; in default mode each edit stops on a dialog, which is G19 and X8's subject, not compliance.

## 11. Build order and Phase 2

1. **Daemon.** Registry, target, poll, the three meta fields, the log events. The channel keeps working against the same daemon.
2. **Mod.** Start from the spike's prototype: delivery and outcome (X3 to X5), then no-outcome with turn matching (X6), X7, waiting (X8).
3. **Mac app.** Launcher and version check, sessions stream and classifier, menu list, then the opt-in.
4. **Wire and iPad.** `sessions`, `selectSession`, `annotation.session`, the switcher, the two-line message.
5. **Eval, dogfood, then removal** of the channel, the flag and `McpConfigManager` (PRD rollout step 3).

**Phase 2, notes only.** Deprioritized with the PRD; nothing is designed. The hooks that would carry it are known: a `tool.call` hook can hold a call while it asks elsewhere, and `tool.check` can return a decision after waiting on one, with the wait kept inside a mods API call so it does not count against the hook's 10 s (*docs*). The spike adds one fact: the permission request reaches a mod with the tool's name and input at the moment the dialog opens, which is what X15's card needs. The open design problem is X14's race between the Mac's own dialog and the iPad's answer, and X12's authenticated link is a prerequisite for X15 whatever the mechanism.

## 12. Decisions and open technical questions

**Decided here, within the PRD.**

- The mod polls at 1 Hz; no long poll, no stream.
- The daemon holds the session registry in memory and owns the target.
- The registry is keyed on a mod instance id, not the Claude Code session id.
- One round in flight per session; a session's claim lasts as long as the session.
- A round's turn is identified by its `turnId`; other turns are ignored.
- X7 is exact equality with the composite path of the round in flight.
- Waiting starts at the permission request and ends per call.
- The opt-in is `CLAUDE_CODE_PLUGIN_DIRS` in the user's settings until the marketplace listing exists; Start session always passes `--plugin-dir`.
- One `sessions` message carries both the list and the waiting state.
- The prompt is sent framed, not `asUser`.

**Decided by the owner, 2026-10-05.**

- **Interrupted turns.** A round whose turn the user interrupts is failed at once, with no reminder (4.3). Now part of X6.

**Still not run.**

- **Screen Recording, literally (SQ4).** Quit Design Canvas, start a session with the mod, and confirm the app the mod opens captures without a new permission question. Needs a moment when the signed build is not in use. Expected to pass on the responsibility result.
- **The user's real settings file (TQ5).** `CLAUDE_CODE_PLUGIN_DIRS` under `env` in `~/.claude/settings.json` itself, and the behaviour under `disableSideloadFlags`, which needs managed settings.
- **The channel baseline for SQ2.** Planned for rollout step 2. The mod's 10 of 10 cannot be below it.
- **The eval with a real iPad and real screens**, per [reply-compliance-eval.md](./reply-compliance-eval.md).
- **`$.store` and `$.ui.toast`** for the X19 notice.
- **`/resume` and `/branch`**, assumed to behave as `/clear` did.
- **A Console API key** (SQ1, closed on the docs).

## 13. As built (2026-10-05)

Phase 1 is implemented as specified above, with the differences below. Nothing is committed to `main`.

**Where things are.**

| Part | Files |
|---|---|
| Daemon | `server/src/sessions/` (registry, round hand-out, sessions stream), routes in `server/src/http/server.ts`, the sweep in `server/src/index.ts`, `claimForSession` and `markReminded` in the store |
| Mod | `mod/` (`hooks/register.js`, about 580 lines, a third of it comments), bundled by `tools/bundle-mod.sh` |
| Mac app | `ClaudeLauncher` (command, version check), `ClaudeSettingsManager` (the opt-in), `SessionStateClassifier`, `AppModel`, the menu's session list, Settings. `McpConfigManager` is deleted |
| Mac engine | `DaemonClient` (sessions, stream, target), `CanvasHub` and `CanvasSession` (relay to the iPad, `selectSession`, `annotation.session`) |
| Wire | `Shared/CanvasMessages.swift`; routing in `Shared/Protocol.swift`, `Shared/CanvasReceiverState.swift`, `Mac/MacSender.swift`; `PROTOCOL.md` 11.2 and 11.3 |
| iPad | `CanvasModel` (sessions, Done, waiting), `ConnectionStatusView` (switcher), `AgentRepliesView` (two-line message), `DrawModeOverlay` |

**Differences from the sections above.**

- **`$.clock.every` returns a timer object with `cancel()`**, not a stop function. The first build called it as a function inside `session.end`; the throw was swallowed by the hook's own guard and the session never deregistered. Found in a live run, not by the unit tests, whose fake had the same wrong shape. Both are fixed.
- **Default target.** "Launched by the app" is any session carrying a launch nonce, not specifically the app's current one (3.3). The app still uses its own nonce to know when its launch has arrived.
- **Binding is done by the daemon**, not the Mac engine (section 5). The engine only passes the iPad's choice through.
- **Session end is one request** (4.3).
- **The reply tool's failure text for a 400** is its own sentence; the channel had none because it validated first.
- **`ChannelAxis`** in the classifier is `none`, `launchPending`, `connected`. A foreign daemon that has sessions shows as "Connected elsewhere" and is not usable from this app.
- **The Connected row's button is "New Session"**, replacing Disconnect, which had nothing left to do: a session ends in its Terminal.
- **Launch help.** When a launch has not connected after 60 s the menu names the trust question and the organisation block (6.1).
- **In Draw Mode with a pick needed**, the overlay carries its own session menu, because the status panel is hidden there (section 7 put the pick only in the panel).

**What has been run.**

- 153 server and mod tests, 456 Design Canvas Swift tests, OpenDisplay's own 60, and builds of the Mac app, the iPad app and the OpenDisplay receiver. `claude plugin validate --strict` passes on the mod, in the checkout and as bundled in the built app.
- The real mod against the real daemon (scratch port and store) in live Claude Code sessions with synthetic sketches: registration with title, branch and launch nonce; queued to sent to applied, one per turn; `waiting` entered and left around a permission dialog in default mode; the exact-path read approved; the daemon restarted under a live session, which re-registered and kept the target; a session killed mid-round, which deregistered and had both its in-flight and its queued round failed.

**What had not been run on 2026-10-05:** the Mac app itself, the iPad app on a device, the every-session option against the real settings file, and the mod opening the Mac app.

These were the entries for the hardware pass below.

**Hardware pass, Mac side (2026-10-06).** A signed Debug build of the Mac app (same bundle id and team as the Xcode build), the new iPad build installed on the iPad over USB, Claude Code v2.1.289. The Mac app was driven through macOS UI scripting, reading the menu's own text and clicking its buttons; sketches were synthetic and posted to the app's daemon under the iPad's device id, since nobody was drawing.

| Check | Result |
|---|---|
| First-launch question (X20) | Appeared once with the two consequences stated. "Not Now" left `~/.claude/settings.json` byte-for-byte unchanged; it did not appear again on relaunch |
| A session started by hand with the bundled mod (X9) | Connected. Menu: "Connected", "Sketches go to project" |
| A round through the app's daemon, default permission mode (X3 to X5, X7, X8) | queued, sent, waiting while the edit's dialog was open, applied. The sketch read raised no dialog |
| Two sessions (X21, X22, X24) | The first stayed the target. Menu: "2 sessions · sketches go to project" with a row per session. A click on the other row moved the target (logged `by: mac`) |
| App quit and relaunched with both sessions running (X9) | Both re-registered within the poll interval; the target was restored (logged `by: restored`) |
| App quit, then a new session started (X19, SQ4) | The mod opened the app, which ran under launchd, not under Claude Code. Capture started 2 s later and the system's own record shows Screen Recording allowed with no new question |
| Every-session switch (X18, X20) | On added one `env` entry to the real settings file. `claude` run with no flag then connected. Off removed the entry |
| Start with a picked project (X1, X2, X10) | Terminal opened `claude --plugin-dir` with the app's mod. The version check passed against the real login shell. The session registered with its launch nonce and a round was applied. Nothing was written into the project |

**Found in the pass.**

- **The settings switch rewrites the whole file.** Content after on-then-off is identical to the original, key for key, but the bytes are not: `JSONSerialization` re-sorts the top-level keys and reformats. For a file the user edits by hand this is more than "one entry". Not fixed; it needs a text-level edit that leaves the rest of the file as written.
- **A fresh launch can raise macOS's screen-capture consent** ("bypass the system private window picker"). It appeared when the new build was first launched and not on later launches, including the one the mod made. It is the access the app already had, re-confirmed by the system; X19's promise holds only after it has been answered once.
- **Run from inside `~/Documents`, the app asks for the Documents folder**, because it reads and starts its own bundled server from there. Seen with the build in the repo's `build/` directory; not seen with the same build copied elsewhere. An installed copy is unaffected.
- **The menu's buttons have no accessibility names**, the new session rows included (only their help text is exposed).
- **The iPad shows in the menu as "iPhone / iPad"**, where the previous build showed its name. Not traced; nothing in this change touches device naming.

**Found after the pass, the same day: an old `.mcp.json` entry stops the mod.** In a project that still has the `design-canvas` entry earlier versions wrote for the channel, a session loaded the mod and never connected. Claude Code serves a mod's tools as an MCP server named after the plugin, the plugin was named `design-canvas`, and the project's own server of that name took its place: the reply tool never appeared, `$.tool.register` did not complete, and because the tool was registered before the tick was started, inside one guard, the session sat loaded and silent. This is the case X2 and XG5 decided to leave alone ("the old entry is not touched"); leaving it alone is still right, but it was not harmless.

Two changes, both verified in that project:

- **The plugin is now named `designcanvas`**, so the tool is `mcp__designcanvas__reply` and Claude reads "The designcanvas plugin sent a message". Every earlier mention of `mcp__design-canvas__reply` in this document, and the spike's results, were under the old name.
- **Startup no longer hangs on one step.** The tick starts whatever happens in `session.start`; the reply tool is registered on the tick, with backoff, until it succeeds; and a session registers with the daemon only once it has the tool, since a session that cannot report an outcome must not be offered sketches.

A Mac app built before this change still carries the old name, and so does a settings entry that points at it; both are replaced by rebuilding the app.

**Still not run.**

- Everything a person has to see or do on the iPad: the session switcher, "Waiting at the Mac", the two-line reply, Done held for a pick, and a real drawn sketch reaching the target session.
- WiFi, `/resume`, an organisation's block, a Console API key, and the version check refusing an old Claude Code.

## Sources

- [PRD-ClaudeMods.md](./PRD-ClaudeMods.md) for every X, XG and SQ.
- Claude Code docs, read 2026-10-04 and 2026-10-05: [mods API](https://code.claude.com/docs/en/plugins/mods/api), [events](https://code.claude.com/docs/en/plugins/mods/events), [reference](https://code.claude.com/docs/en/plugins/mods/reference), [admin](https://code.claude.com/docs/en/plugins/mods/admin), [troubleshoot](https://code.claude.com/docs/en/plugins/mods/troubleshoot).
- The type declarations Claude Code v2.1.289 wrote for a mod loaded with `--plugin-dir` (`.claude-plugin/types/claude-code/index.d.ts`): `PromptSubmitArgs`, `PromptSubmitAttachment`, `ToolCheckInput`, `ToolCheckResult`, `PermissionRequestHookInput`, `UserPromptSubmitHookInput`, and the `$.ui.notice` declaration.
- The spike of 2026-10-05 (section 10) and the earlier throwaway mod of the same day.
- In the repo: `server/src/channel/`, `server/src/http/server.ts`, `server/src/store/rounds.ts`, `Mac/App/ClaudeLauncher.swift`, `Mac/App/McpConfigManager.swift`, `Mac/App/SessionStateClassifier.swift`, `Mac/App/AppModel.swift`, `iOS/AgentRepliesView.swift`, `iOS/ConnectionStatusView.swift`.
