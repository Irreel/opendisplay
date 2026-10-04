# Design Canvas: Technical Specification

**Status:** Draft v0.4, 2026-10-03 (v0.3 was 2026-09-18, after the first hardware sessions; v0.2 was 2026-09-16, after the engineering review of the same day). Companion to `PRD-DesignCanvas.md` v0.8. The blank canvas surface is specified separately in `technical_doc-BlankCanvas.md`. Requirement IDs (D, C, M, P) and gap numbers (G) are shared with the PRD.
**Sources:** ai.cst.2 (tech-doc v0.5, desktop-app.md, ADR-0001 to ADR-0004, `packages/server/src/channel/index.ts`); OpenDisplay `PROTOCOL.md` (pv 3) and `Mac/MacSender.swift`; the Claude Code Channels reference and the fakechat reference channel, both read 2026-09-16.

**Document history**

| Date | Change |
|---|---|
| 2026-09-16 v0.1 | Split from the PRD |
| 2026-09-16 v0.2 | Engineering review applied: GPL-3.0 final and in-app engine; no input forwarding; frame ring instead of a fresh still; Mac composites, sketch-only wire; canvas frame cap with chunked reads; trust-on-first-use accepted; no captureId round-trip; rounds snapshot; store under `~/.claude/channels`; single DaemonClient; Draw Mode state machine; `sourceLabel` removed; size guards on sender-to-iPad JSON; review outputs and report appended |
| 2026-09-18 v0.3 | G1 decided after the first hardware sessions: mirror the Mac's main display, no extended display. Sections 1, 3, 5.6, 7 and 10 updated; section 11 left as the dated record of the 2026-09-16 review |
| 2026-10-03 v0.4 | Header brought up to date (the 2026-09-30 `existing` channel state in section 2 had not been recorded here; companion PRD is v0.8). Sections 2 and 3 point to `technical_doc-BlankCanvas.md` for the blank canvas surface, which this document does not describe |

## 1. Architecture

```
Mac                                                          iPad
┌───────────────────────────────────────────────┐
│ Design Canvas menu-bar app (Swift, one process)│
│  ├─ SenderEngine module (OpenDisplay-derived)  │
│  │    main-display capture, frame ring, H.264 ─┼──USB/WiFi──▶ Design Canvas app
│  │    freeze / annotation / agentReply / rounds│            (OpenDisplay receiver core
│  │    NO input injection                       │             + Draw Mode + Agent replies)
│  ├─ DaemonClient (HTTP + SSE, loopback)        │
│  └─ supervises ▼                               │
│ designtool --http (Node)   store, events       │
│        ▲ loopback SSE + claim/served/reply     │
│ designtool --channel (Node) ◀── stdio ── Claude Code (user's terminal, repo cwd)
└───────────────────────────────────────────────┘
```

| Process | Lifetime | Owns |
|---|---|---|
| Menu-bar app | While open | Daemon supervision with crash-loop guard, project picker, `.mcp.json` management, Start session, Reset, session-state classifier, status UI (D2, D3, D7). Hosts the engine module and the DaemonClient |
| SenderEngine module (in-process) | With the app | ScreenCaptureKit stream of the Mac's main display (mirror only; no virtual display is created), frame ring, encoder, the only connection to the iPad, the only LAN-facing code. Behind a `SenderEngine` protocol so it is fakeable in tests. No input injection (D1, D9, D10) |
| `designtool --http` | While the app is open | HTTP on `127.0.0.1` only, filesystem store, SSE event stream. Single writer to the store (D4, D8) |
| `designtool --channel` | While Claude Code has it spawned | MCP over stdio: `claude/channel` capability plus the reply tool. Subscribes to the daemon; claims, emits, marks served (D5, D6) |

**Decided in review.** The engine is an in-app module, not a separate process: with GPL-3.0 as the final license (section 7) the process boundary had no remaining purpose. The iPad never controls the Mac: no `touch`, `scroll`, `pencil`, or `proximity` is sent on a canvas session, the engine omits `InputInjector`, and the app never requests Accessibility. Screen Recording is the only TCC grant.

**Decided after the first hardware sessions (G1, owner, 2026-09-17).** Design Canvas mirrors the Mac's main display and has no extended display. It runs OpenDisplay's existing mirror capture path: ScreenCaptureKit captures the first display macOS reports (normally the main one) at its native pixel size times the quality scale, and no `CGVirtualDisplay` is created. The mode is fixed rather than defaulted (`SenderControllerConfig.fixedMode = .mirror`, resolved by `CaptureMode.resolve(stored:fixed:)`), so a stored `mode` default or a `-mode` launch argument cannot select extend. OpenDisplay itself keeps its user-selectable mode. Consequences:

- The stream has the Mac's resolution and aspect ratio, not the iPad's. The iPad aspect-fits it, so there are letterbox bars, and `zoomRect` is normalized to the picture rather than to the iPad's screen (`ZoomModel.fittedRect`), so a crop lines up wherever the bars fall. `hello`'s panel size and `maxEncodeWide/High` do not size a mirrored stream, and a rotation re-`hello` rebuilds nothing.
- The encode size follows the Mac's panel, for example 3024x1964 for a 1512x982-point Retina panel. H.264 tops out near 4096x2304, so a 5K main display at the default quality exceeds it (OpenDisplay upstream #271 describes the same ceiling). Until the app has a quality control of its own, the sender's `quality` default (`balanced` 75%, `fast` 50%) is the workaround.
- Everything on the main display is streamed to the iPad, and a round sent without zooming in captures the whole screen. This widens G13 (redaction) and is why D20's terminal ends up in frame.
- No virtual display means none of macOS's saved per-display state is involved. The first hardware session failed on exactly that: macOS held state under which the display identities it was offered never came online (OpenDisplay upstream #206 and #221), so nothing was ever captured.

**Invariants carried from ai.cst.2.** The daemon is the only writer to the store. An annotation is immutable once written; only its meta state changes. The channel directory is the only code that imports the MCP SDK (lint-enforced). No code in Design Canvas calls an LLM or edits user source. Every request, notification, reply, and state change is logged as JSON lines.

**Why the daemon is loopback-only.** OpenDisplay's core invariant is that the receiver listens and the Mac connects, because usbmuxd can only open connections toward the device. ai.cst.2's iPad-to-Mac HTTP upload cannot work over USB. With OpenDisplay pairing adopted (G21), the annotation travels on the OpenDisplay connection and the daemon drops Bonjour, the 6-digit code, and bearer tokens.

**Security posture (G3 in review, decided).** OpenDisplay's trust-on-first-use stands for the MVP: remembered WiFi devices auto-reconnect by their cleartext Bonjour `id`, new ones need a click. A LAN neighbour who spoofs a remembered id can therefore push a sketch into the session. Documented in onboarding with a recommendation to use USB on shared networks. The fix is encrypted transport with pairing (OpenDisplay #16, TODOS.md), which also gates the future permission relay.

## 2. Wire additions to OpenDisplay

Additive JSON control messages, no `pv` bump, gated on `welcome.canvas: true`. An old sender ignores them; an old iPad never sends them. On a canvas session the receiver sends no input messages at all.

| Message | Direction | Fields | Purpose |
|---|---|---|---|
| `freeze` | iPad to Mac | `captureMs`, `zoomRect`, `t` | Draw Mode entered on the frame captured at `captureMs` (from the frame's telemetry prefix, PROTOCOL.md 5.1); zoom locked (M1, D9) |
| `frozen` | Mac to iPad | `ok` | `true` when the ring held the frame; `false` only if no frame exists (M7) |
| `annotation` | iPad to Mac | `sketch` (base64 PNG, transparent), `zoomRect`, `viewport`, `note`?, `t` | The finished round; sketch only, no composite (M5, D10) |
| `agentReply` | Mac to iPad | `annotationId`, `status`, `message`? (≤ 2 KB), `prUrl`?, `t` | Claude Code's outcome (D6, M8) |
| `rounds` | Mac to iPad | `rounds[]` of `{annotationId, createdAt, status, message?, prUrl?, note?}` | Snapshot of the last 20 rounds for this device, sent after every `hello` (M8) |

`ping` (sender to receiver) gains two additive string fields: `channel` and `project` (selected folder name, absent when unselected) (P1). `channel` is the Mac menu's D7 verdict, not the daemon's raw subscriber count, so the iPad's dot can never contradict the Mac's row: `attached` (this app's own session), `existing` (a session the app did not start — the menu's "Another session"), `detached` (daemon up, no channel), `none` (no usable daemon). A receiver reads an unknown value as `none`.

The blank canvas surface (2026-10-03) adds `annotation.base` and `ping.blank`; they are specified in `technical_doc-BlankCanvas.md` section 2 and `PROTOCOL.md` section 11.

**Frame length policy (review 2A and D16).** Today `Mac/MacSender.swift:1664` rejects any receiver-to-sender frame of 1 MiB or more with a bare `return`, which never re-arms the read and silently stops all control input while video continues. Replace with a `ControlFramePolicy` struct: cap 1 MiB without `canvas`, 16 MiB with it; payloads are read in 256 KiB chunks and `lastReceived` is bumped per chunk so the 5 s watchdog (line 1424) sees bytes flowing during a slow upload; an oversize frame calls `linkDied` with a log line. Tested in the hostless MacTests target.

**Sender-to-iPad size rule (D23).** `sendJSONFrame` (line 2232) refuses and logs any payload of 32768 bytes or more so the section 4 demux heuristic can never misread a control message as video. The channel process truncates `agentReply.message` at 2 KB before it reaches the daemon; the full text stays in the store.

## 3. Capture at freeze and Draw Mode

This section describes a round on the mirror surface. A round on the blank canvas surface uses no frame, no `freeze` and no ring; see `technical_doc-BlankCanvas.md` sections 3 and 4.

**Frame ring (D15).** The engine keeps a ring of recently captured frames keyed by capture ms, stored at the encode size so memory stays bounded. As built, the ring is a frame count, the last 16 frames, not ~2 s: deep copies of two seconds of full frames would cost hundreds of MB (implementation plan, ruling 6). Under mirroring (G1) the encode size is the Mac's panel, so the bound is about 16 x 8.9 MB = 143 MB for a 3024x1964 stream in the default 420v pixel format, against about 75 MB for an iPad-sized 2048x1536 stream. On `freeze` it picks the frame whose capture ms matches the iPad's `captureMs` (nearest, within one frame interval), converts to PNG, and posts it to the daemon as the capture. The base frame is therefore the exact frame the user drew on, in clean pre-encode pixels. There is no iPad fallback frame: `frozen.ok:false` means no frame exists yet, which cannot happen in Draw Mode; the iPad then leaves Draw Mode with a message and keeps the strokes.

**Join (review 4A).** The engine holds the last freeze capture per connection. On `annotation` it attaches that capture, the install id, and the device name, and posts to the daemon. A second `freeze` before Done discards the first capture with a log line. No capture id crosses the wire.

**Compositing (review 1A).** The engine, on a serial utility queue (review 11A), decodes the sketch, crops the clean frame to `zoomRect` when the user had zoomed in (G8) or uses the full frame otherwise, flattens the sketch over it, caps the long side at about 1568 px, and posts `composite.png` and `sketch.png`. The full-resolution capture is kept as `screenshot.png`. The receive loop is re-armed before any of this starts, so pings and the next messages are never blocked.

**Draw Mode state machine (review 8A).** Pure struct in `Shared/`, tested in MacTests; the iOS layer drives PencilKit from its transitions.

```
            pinch/pan (view-only, no forwarding)
   ┌────────────────────────────────────────────────┐
   ▼                                                │
 LIVE ──enter Draw Mode──▶ FREEZING ──frozen.ok──▶ DRAWING ──Done (≥1 stroke)──▶ SENDING ──sent──▶ LIVE
   ▲                          │  │                     │  │                          │
   │      frozen.ok=false or  │  │ cancel              │  │ cancel / discard         │ link lost:
   │      2 s timeout ────────┘  └──────▶ LIVE         │  └──────▶ LIVE               │ keep sketch,
   │      (message shown)                              │                              │ resend on hello
   │                                                   │ rotation or link lost:       ▼
   └───────────────────────────────────────────────────┘ strokes kept, back to LIVE, RETRY ──▶ SENDING
                                                         Draw Mode re-entered by the user
 Done is disabled while the stroke count is 0.  A second freeze is not possible: FREEZING and DRAWING ignore it.
```

## 4. Store (D4)

Location: `~/.claude/channels/design-canvas/` (review 6A, the fakechat convention), so the composite path in the notification is inside Claude Code's own area.

```
<store>/annotations/<uuid-v7>/
  meta.json   screenshot.png   sketch.png   composite.png   note.m4a?
<store>/captures/<id>/  meta.json  screenshot.png
```

`meta.json` (schema v3): `id`, `schemaVersion`, `createdAt`, `claimedAt`, `servedAt`, `viewport`, `zoomRect`, `note{text, voiceFile}`, `sourceCaptureId`, `device{id, name}`, `reply{status, message, prUrl, at}`. `sourceLabel` is removed (D18); a v2 record reads with the field ignored.

States: `pending` → `serving` (30 s lease) → `served`; `reply` is set independently and may arrive after `served`. Clear deletes the directory. A pending TTL is deferred (TODOS.md).

## 5. Claude Code integration

### 5.1 Mechanism

Claude Code Channels (research preview). The channel process declares `claude/channel` and pushes notifications; Claude Code acts without a typed prompt. No polling. One tool, the reply. Launch and config, managed by the menu-bar app:

```
claude --dangerously-load-development-channels server:design-canvas
```

```json
{ "mcpServers": { "design-canvas": { "command": "designtool", "args": ["--channel"] } } }
```

### 5.2 Delivery (D5)

- Engine posts the annotation; daemon writes it `pending` and emits `annotation.pending` on SSE.
- Channel process claims it (`pending` → `serving`, 30 s lease; 200 to one winner, 409 otherwise), emits the notification, marks it `served`.
- A daemon sweep resets expired leases to `pending`. Delivery is at-least-once; a rare duplicate is preferred to a lost sketch.
- Backlog: on channel connect, pending annotations replay in order at one per second.
- Claude Code queues events that arrive while it is busy and delivers them together on the next turn (G10).

### 5.3 Notification

`notifications/claude/channel` with `content` (string) and `meta` (string map). Content:

```
New annotation from iPad.
Annotation ID: <uuid v7>
Device: <iPad name>
Captured at: <iso>
Sent at: <iso>
Composite PNG path: <absolute path under ~/.claude/channels/design-canvas/>
Zoom region: <normalized rect, or "full frame">
Note: <text or "(none)">

Inspect the composite PNG path to see the visual annotation.
Apply this annotation to the source code, then call design_canvas_reply with the outcome.
```

`meta`: `source`, `annotation_id`, `device`. Server `instructions` tell Claude Code that events arrive as `<channel source="design-canvas">`, to read the PNG, and to reply once per annotation.

### 5.4 Reply tool (D6)

`design_canvas_reply(annotation_id, status: applied | failed | needs_input, message?, pr_url?)`. Registered with `tools: {}` in capabilities and the standard list/call handlers. `message` is truncated at 2 KB. The channel process posts it to the daemon, which stores it in `meta.reply` and emits a reply event; the engine forwards `agentReply` and includes it in the next `rounds` snapshot. Nothing is sent back into Claude Code in response; `needs_input` is answered by a new round.

**Rounds snapshot (review 5A).** After every `hello` the engine fetches `GET /v1/rounds?device=<install id>` (last 20) and sends `rounds`, so the iPad is stateless and a reply that landed while disconnected is shown on reconnect. Live `agentReply` only updates the list.

**No reply timeout (owner decision D21).** A round with no reply stays `sent`. The reply-compliance eval (section 11) is the measurement path for the "rounds that receive a reply" metric.

### 5.5 Image delivery (G23, decided)

The notification carries the composite's file path; Claude Code's Read tool renders PNGs. The channel contract carries only a string `content`, so an image block is not expressible; the ai.cst.2 tech-doc is corrected. Inline base64 is ruled out (text tokens). An MCP tool returning an image block is the recorded upgrade path (TODOS.md), triggered by replies showing the model acting without reading the sketch or by the embedded backend.

### 5.6 Constraints

- Claude Code only. claude.ai login only (Console API keys cannot use Channels).
- Development flag required until marketplace listing.
- Protocol may change; the channel adapter is isolated.
- Terminal permission prompts still fire and no reply arrives while one waits (G19). **Owner decision (D20):** the MVP mitigation is to keep the terminal window on the mirrored display so the prompt is visible from the iPad. Since G1 that is the Mac's main display, where the terminal opens anyway; with more than one monitor it must stay on the main one. Consequence, recorded from the outside voice and accepted: the clean capture and composite may include the terminal, which then travels back into Claude Code's context; zooming into the preview region before drawing keeps it out of the crop.
- **Unverified assumptions kept by owner decision (D22):** that Read on the store path never prompts, and that the `.mcp.json` entry does not trigger the project-MCP trust prompt for the user or for collaborators who inherit the committed file. If either prompts, the fix is an app-managed allow rule or a user-scoped MCP config.
- Manually launched Claude Code sessions are unsupported; the app recognizes only a channel it started (ADR-0004).

### 5.7 Permission relay (future, G19)

Channels defines it: declare `claude/channel/permission`; receive `notifications/claude/channel/permission_request` with `request_id`, `tool_name`, `description`, `input_preview`; answer with `notifications/claude/channel/permission` carrying `request_id` and `behavior: allow | deny`. The terminal dialog stays open in parallel; first answer wins. Blocked on an authenticated sender path, which is encrypted transport (TODOS.md).

## 6. Session ownership (D7)

From ai.cst.2 ADR-0004. Daemon identity is self-reported on `/v1/health` (`pid`, `instanceId`, `startedAt`, `channelCount`, `channelAttachedAt`) and re-verified every 2 s. A channel is "owned" only if this app run launched Claude Code while `channelCount` was 0. Anything else is "existing session detected"; the only way out is Reset, which stops verified Design Canvas helper processes and never kills Claude Code (G22).

## 7. Packaging and license (G14, G27, decided)

- **License: GPL-3.0, final.** Design Canvas is a derivative of OpenDisplay and stays under the same license. No engine process boundary, no clean-room receiver, no dual-license request.
- **Separate app built on OpenDisplay's code.** New Design Canvas targets in the OpenDisplay project (`project.yml`, xcodegen) compile `Shared/`, the `Mac/` sender pieces minus `InputInjector`, and the iOS receiver. Since G1 the virtual-display pieces (`VirtualDisplay.swift`, `DisplayArrangement.swift`, `TestPatternWindow.swift`, the private `CGVirtualDisplay` header) are compiled in but never run: OpenDisplay's `MacSender.swift` references them, and leaving them out would mean conditional compilation inside an upstream file. Design Canvas-specific code lives in new directories: engine wrapper, frame ring, compositor, DaemonClient, Draw Mode, Agent replies, and the menu-bar shell reused from ai.cst.2 (`AppModel`, `DaemonSupervisor`, `ClaudeLauncher`, `McpConfigManager`, `SessionStateClassifier`, `ProcessResetService`, `ProjectRecents`).
- **Own identity.** Distinct product names, bundle ids, and icons on both platforms, with OpenDisplay's Debug-id separation so dev builds do not invalidate release TCC grants. Screen Recording only; no Accessibility.
- **Own discovery.** The iPad advertises `_designcanvas._tcp` with the same TXT keys, so OpenDisplay senders and Design Canvas iPads do not dial each other.
- **Distribution.** Mac: outside the Mac App Store (Developer ID, notarized, Sparkle with its own appcast). Since G1 the private CGVirtualDisplay API is no longer used at runtime, but it is still linked (see above), and the app supervises a Node process and launches Terminal, which an App Store sandbox would not allow. iPad: App Store or TestFlight. CI: the existing `tests.yml` pattern (unsigned `xcodebuild test` on the Mac scheme, build of the receiver scheme) extended to the new targets; release pipeline mirrors `release.yml`.

## 8. Changes from ai.cst.2

| ai.cst.2 | Design Canvas |
|---|---|
| On-demand hotkey capture of the frontmost window; iPad fetches latest capture | Frame picked from the engine's ring at the iPad's `captureMs` |
| iPad composites over its own frame (PencilCanvasView.renderedPNGs) | Mac composites over the clean frame; iPad sends the sketch only |
| Browser extension as legacy capture path | Dropped |
| iPad discovers daemon over Bonjour, 6-digit code, LAN HTTP with bearer token | OpenDisplay pairing and connection; daemon loopback-only |
| `sourceLabel` (window title) | Removed |
| Store under `~/Library/Application Support/DesignTool/` | `~/.claude/channels/design-canvas/` |
| One-way channel, no tools | One reply tool, 2 KB message cap |
| HealthClient + CaptureUploader | One DaemonClient |
| "No re-mirror after edits" | Live mirror is the point |
| iPad queue view | Deferred; records kept; `rounds` snapshot instead |
| Principle P3 "no tools, no pull" | Amended: one notification per send, one reply tool, no pull |

## 9. Future: embedded agent backend

If pursued, add an agent backend abstraction in the daemon with two implementations: the channel process (default) and a Claude Agent SDK runner on the user's Mac. The notification text becomes the runner's prompt, the composite its image input, and the runner emits the same reply events. Managed Agents does not fit: the repo and dev server are not in its sandbox. Needs an ADR; it reverses "no LLM calls."

## 10. Decisions and open technical questions

**Decided.** G1 the iPad mirrors the Mac's main display; no extended display, and the capture mode is fixed (section 1; owner, 2026-09-17, after the first hardware sessions). G2 Channels with one reply tool. G3 payload: sketch, note, viewport, zoom rect, device, reply; composite built on the Mac. G4 minimal reply. G7 no input forwarding, so no gesture handoff exists; zoom is view-only. G8 crop when zoomed. G14 separate app, in-app engine module, own ids and Bonjour type. G15 iPad and macOS only. G16 UUID v7 per round with reply stored. G20 base frame from the engine's ring at the iPad's capture time; no fallback frame. G21 OpenDisplay pairing only; daemon loopback-only. G23 file path in the notification. G24 device tagging. G25 canvas cap 16 MiB with chunked reads. G26 store under `~/.claude/channels/design-canvas/`. G27 GPL-3.0 final. Security: trust-on-first-use for the MVP.

**Open.**

- **G10.** Batched events: whether two sketches in one turn produce good edits is untested (TODOS.md measurement).
- **G19.** Permission relay blocked on encrypted transport; mitigation is the terminal on the mirrored display by owner decision.
- **Vector strokes** (proposed, not decided): keep normalized stroke data next to `sketch.png` for future element mapping.

## 11. Engineering review outputs (2026-09-16)

### NOT in scope

- Input forwarding of any kind from the iPad (owner decision; removes Accessibility).
- Permission relay to the iPad (blocked on encrypted transport).
- Encrypted WiFi transport and pairing code (TODOS.md; OpenDisplay #16).
- Reply timeout and synthetic `timed_out` status (owner declined, D21).
- Pre-implementation spike of the two Claude Code prompt assumptions (owner declined, D22).
- Pending-round TTL (TODOS.md).
- Image-block MCP tool (TODOS.md).
- Stack, re-send of a failed round, element selection, voice transcription, marketplace listing, embedded agent, other agents, cloud relay, vector strokes (PRD future list).
- Crash isolation of the engine in its own process (not needed; revisit only if sender crashes prove painful).

### What already exists

| Sub-problem | Existing code | Plan |
|---|---|---|
| Mirroring, pairing, discovery, USB | OpenDisplay `Mac/`, `Shared/`, `iOS/` | Reused as-is |
| Last-frame cache | `Mac/MacSender.swift:337 lastPixelBuffer` | Extended into a ring keyed by capture ms |
| Control read loop and watchdog | `Mac/MacSender.swift:1645-1668, 1421-1424` | Modified: policy struct, chunked reads |
| Daemon store, claim/lease, SSE, health identity | ai.cst.2 `packages/server` with node:test suites | Reused; reply endpoint, rounds endpoint, loopback bind, path and schema changes added |
| Channel adapter, backlog, harness | ai.cst.2 `packages/server/src/channel`, `scripts/channel-harness.mjs` | Reused; reply tool added |
| Swift daemon clients | ai.cst.2 `HealthClient.swift`, `CaptureUploader.swift` | Merged into one DaemonClient |
| Menu-bar shell, supervision, launcher, session classifier, reset | ai.cst.2 `apps/desktop` | Reused |
| PencilKit canvas and PNG export | ai.cst.2 `PencilCanvasView.swift` | Reused for the sketch layer; its composite path dropped |
| ScreenCaptureKit window still | ai.cst.2 `WindowCapturer.swift` | Not needed; the ring replaces stills |
| Pinch-zoom | Does not exist in OpenDisplay iOS | New, view-only |

### Failure modes

| New codepath | Realistic failure | Test | Handling | User sees |
|---|---|---|---|---|
| Frame ring lookup | `captureMs` older than the ring | unit | `frozen.ok:false`, iPad exits Draw Mode with a message | Clear message |
| Chunked read | Link drops mid-upload | unit + E2E | `linkDied`; sketch kept on the iPad, resent on reconnect | Round shows retry |
| Oversize frame | Sketch over 16 MiB | unit | Link closed with a log line | Reconnect, strokes kept |
| Compositor | zoomRect outside bounds, empty sketch | unit | Clamp; composite equals crop | Nothing wrong |
| DaemonClient | Daemon down at Done | unit | Annotation held in the engine, retried with backoff; `ping.channel = none` | Status shows Mac hop down |
| Reply SSE | Daemon restarts | unit | Reconnect with backoff; `rounds` on next hello | Status catches up |
| Notification | Claude Code drops the event (channel not loaded) | E2E | None possible (no ack); round stays `sent` | **Critical gap:** silent, no timeout by decision |
| Reply tool | Model never calls it or is stuck behind a permission prompt | eval | None by decision (D21) | **Critical gap:** round stays `sent` forever |
| `sendJSONFrame` guard | Reply over 32 KiB | unit | Truncated at 2 KB upstream; refused and logged at the sender | Truncated message |
| Store path | Read prompts in the terminal | none (spike declined) | None | Prompt on the Mac, invisible from the iPad |
| `.mcp.json` entry | Project-MCP trust prompt for a collaborator | none (spike declined) | None | Prompt on the Mac |
| Backlog replay | Stale rounds after a restart | none | None (TTL deferred) | Old sketch applied |

Two critical gaps flagged (no test, no handling, silent): a round that never receives a reply, whether because the event was dropped or the tool was not called. Both stem from the declined reply timeout; the reply-compliance eval is the only measurement.

### Worktree parallelization

| Step | Modules touched | Depends on |
|---|---|---|
| A. Messages and state machine | `Shared/`, `MacTests/` | — |
| B. Sender engine: policy, ring, compositor, DaemonClient, session | `Mac/`, `MacTests/` | A |
| C. Daemon and channel | `packages/server`, `packages/shared` | — |
| D. iOS Draw Mode and Agent replies | `iOS/` | A |
| E. Menu-bar app integration | `Mac/` app shell, ai.cst.2 `apps/desktop` | B, C |
| F. E2E, device checklist, eval, docs | `scripts/`, `PROTOCOL.md` | B, C, D |

Lanes: `Lane 1: A → B → E (sequential, shared Mac/)`; `Lane 2: C (independent)`; `Lane 3: D after A (independent of B)`; `Lane 4: F after all`. Launch A and C in parallel worktrees; when A merges, launch B and D in parallel; E after B and C; F last. Conflict flag: B and E both touch `Mac/`; keep E sequential after B.

### Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~4h / CC: ~20min)** — Shared/ — Add CanvasMessages structs, `welcome.canvas` gate, and DrawModeStateMachine as pure structs with MacTests coverage
  - Surfaced by: Code quality 9A, tests 10A
  - Files: `Shared/CanvasMessages.swift`, `Shared/DrawModeStateMachine.swift`, `MacTests/…Tests.swift`, `project.yml`
  - Verify: `xcodebuild test -scheme OpenSidecarMac … -only-testing:OpenSidecarMacTests`
- [ ] **T2 (P1, human: ~4h / CC: ~20min)** — Mac/ read loop — ControlFramePolicy: 1 MiB default, 16 MiB on canvas, 256 KiB chunked reads bumping liveness, oversize closes the link with a log line
  - Surfaced by: Architecture 2A; outside voice 2 (D16)
  - Files: `Mac/ControlFramePolicy.swift`, `Mac/MacSender.swift:1645-1668`, `MacTests/ControlFramePolicyTests.swift`
  - Verify: unit tests for cap, chunk boundary, oversize path
- [ ] **T3 (P1, human: ~1d / CC: ~30min)** — Mac/ capture — Frame ring keyed by capture ms; freeze picks the iPad's frame; capture posted; `frozen {ok}`; no fallback path
  - Surfaced by: Outside voice 1 and 10 (D15); architecture 4A
  - Files: `Mac/FrameRing.swift`, `Mac/FreezeCapture.swift`, `Mac/MacSender.swift`
  - Verify: ring lookup tests; manual round shows the frame drawn on
- [ ] **T4 (P1, human: ~1d / CC: ~30min)** — Mac/ compositor — Crop to zoomRect, flatten sketch, 1568 px cap, clamp, empty sketch
  - Surfaced by: Architecture 1A
  - Files: `Mac/Compositor.swift`, `MacTests/CompositorTests.swift`
  - Verify: pixel-level unit tests on fixtures
- [ ] **T5 (P1, human: ~4h / CC: ~20min)** — Mac/ DaemonClient — Merge HealthClient and CaptureUploader; add annotation POST, reply SSE with backoff, rounds GET
  - Surfaced by: Code quality 7A
  - Files: `Mac/DaemonClient.swift`, `MacTests/DaemonClientTests.swift`
  - Verify: URLProtocol-stubbed tests for 201/4xx/5xx/timeout/reconnect
- [ ] **T6 (P1, human: ~1d / CC: ~40min)** — Mac/ sender integration — Serial utility queue for annotation work with receive re-armed first; rounds snapshot on hello; agentReply relay; ping `channel`/`project`; `sendJSONFrame` 32 KiB guard; no input injection on canvas
  - Surfaced by: Performance 11A; architecture 5A; outside voice 3 (D23); no-forwarding (D19)
  - Files: `Mac/MacSender.swift`, `Mac/CanvasSession.swift`
  - Verify: queue-injection tests; guard test; E2E reconnect shows statuses
- [ ] **T7 (P1, human: ~1d / CC: ~40min)** — packages/server daemon — Loopback-only bind; remove pairing, Bonjour, bearer auth; reply endpoint and event; rounds endpoint; store path; schema v3 (drop `sourceLabel`, add `device`, `zoomRect`, `reply`)
  - Surfaced by: Architecture 6A; D18; tests 10A (regression: uploads no longer 401; non-loopback refused)
  - Files: `packages/server/src/http/server.ts`, `src/store/*`, `packages/shared/src/index.ts`, new node:test files
  - Verify: `pnpm --filter @design-canvas/server test`
- [ ] **T8 (P1, human: ~4h / CC: ~20min)** — packages/server channel — `tools: {}` and `design_canvas_reply`; 2 KB truncation; notification text with Device and Zoom region; harness asserts payload
  - Surfaced by: Reply decision; outside voice 3 (D23); tests 10A
  - Files: `packages/server/src/channel/index.ts`, `scripts/channel-harness.mjs`
  - Verify: node:test for list/call handlers; harness run
- [ ] **T9 (P1, human: ~2d / CC: ~1h)** — iOS/ app layer — Draw Mode UI over PencilKit driven by the state machine via receiver delegates; view-only pinch-zoom; no input messages on canvas; Agent replies list; Connection Status with project
  - Surfaced by: Code quality 8A, 9A; D19; outside voice 4 (D17); PRD P1, M8
  - Files: `iOS/DrawModeView.swift`, `iOS/AgentRepliesView.swift`, `iOS/OpenSidecarPhoneApp.swift`
  - Verify: device checklist in the eng-review test plan
- [ ] **T10 (P2, human: ~1d / CC: ~40min)** — Mac/ menu-bar app — Integrate the engine as an in-app `SenderEngine` module; reuse ai.cst.2 app shell; project name into ping; no Accessibility request
  - Surfaced by: Step 0 (D2.1); packaging (G14, GPL final)
  - Files: `Mac/SenderEngine.swift`, ai.cst.2 `apps/desktop/DesignCanvasDesktop/AppModel.swift`
  - Verify: existing desktop XCTest suite plus a fake engine
- [ ] **T11 (P2, human: ~1d / CC: ~40min)** — tests/e2e — Harness E2E for USB and WiFi rounds, backlog flush, reconnect snapshot; device checklist; reply-compliance eval (10 rounds, threshold 9/10)
  - Surfaced by: Tests 10A
  - Files: `scripts/channel-harness.mjs`, `docs/device-checklist.md`
  - Verify: harness green; eval report
- [ ] **T12 (P2, human: ~2h / CC: ~10min)** — docs — PROTOCOL.md addendum for canvas messages and the canvas cap; onboarding note on LAN risk and USB
  - Surfaced by: Architecture 3A; wire additions
  - Files: `PROTOCOL.md`, onboarding copy
  - Verify: doc review

_No new tasks from the declined items (D20, D21, D22, D24); they are recorded in NOT in scope and TODOS.md._

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found (claude subagent; Codex CLI needs upgrade) | 10 findings: 5 accepted, 1 sent to TODOS, 3 declined by owner, 1 already covered |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 41 issues (6 architecture, 3 code quality, 1 performance, 31 test gaps), 2 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CROSS-MODEL:** Claude review and the outside voice agreed on the frame cap and the state-machine placement; the outside voice added the capture-timing, watchdog, size-guard, and no-terminal-state findings; the owner accepted the first three and declined the last.
- **VERDICT:** Eng review has 2 critical gaps open (rounds with no reply have no terminal state, by owner decision D21) — eng review required before ship, or accept the gaps explicitly at ship time.

NO UNRESOLVED DECISIONS
