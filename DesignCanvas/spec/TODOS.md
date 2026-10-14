# TODOS

## Design Canvas

### Encrypted WiFi transport with a pairing code (OpenDisplay #16)

**What:** TLS on the OpenDisplay wire with a self-signed certificate exchanged at first pairing, so WiFi sessions cannot be spoofed or sniffed.

**Why:** The MVP accepts OpenDisplay's trust-on-first-use, which leaves a LAN injection path: anyone who advertises the iPad's cleartext Bonjour id gets dialed and can push a sketch into the user's Claude Code session. The Claude Code Channels reference also requires an authenticated sender before the permission relay can be declared, so this blocks permission prompts on the iPad.

**Context:** OpenDisplay upstream tracks this as roadmap issue #16 (github.com/peetzweg/opendisplay/issues/16). Design Canvas consumes it once upstream or this fork ships it. Start at PROTOCOL.md sections 2.1 and 10 (two-phase migration rules); it is a protocol-version change on both apps. Eng review 2026-09-16, decision 3A.

**Effort:** XL
**Priority:** P1
**Depends on:** None. Blocks: permission relay on the iPad.

### MCP tool returning the composite as an image block

**What:** `design_canvas_get_image(annotation_id)` on the channel server, returning the composite as an MCP image content block, as a second delivery path beside the file path.

**Why:** The file-path form gives the daemon no signal that the model actually looked at the sketch; a tool call is logged. It also works in a sandboxed or remote Claude Code session where the path does not exist, and it is the interface a future embedded-agent backend would use.

**Context:** Decided against for the MVP in technical_doc.md section 5.5 on contract stability and vendor precedent (fakechat sends a path). Build when replies show the model acting without reading the sketch, or when the embedded backend lands. Start in packages/server/src/channel/index.ts beside the reply tool; downscale server-side to about 1568 px before encoding.

**Effort:** S
**Priority:** P3
**Depends on:** Reply tool shipped.

### Measure batched sketches in one Claude Code turn (G10)

**What:** A dogfooding protocol: send a second round while the first is being applied, ten times, and record whether the batched turn produces correct edits for both.

**Why:** The Channels reference says events arriving mid-task are delivered together on the next turn. Whether two sketches in one turn yield good edits is unknown and decides whether the iPad should discourage sending while a round is unanswered.

**Context:** G10 in technical_doc.md section 10. Run with the E2E harness and a real session once the MVP round works end to end.

**Effort:** S
**Priority:** P3
**Depends on:** MVP round working end to end.

### Pending-round TTL

**What:** Mark `pending` rounds older than about 30 minutes as `expired` in the daemon sweep and never emit them; show `expired` in the rounds snapshot.

**Why:** At-least-once delivery plus backlog replay plus Claude Code batching means sketches drawn on a UI that no longer exists replay after a Claude Code restart and get applied to moved-on source. With Stack cut, the iPad has no way to cancel a queued round.

**Context:** Outside-voice finding 8 in the 2026-09-16 eng review; deferred by owner. The daemon already has a lease sweep (packages/server, claim lease 30 s) to extend. Revisit together with Stack.

**Effort:** S
**Priority:** P3
**Depends on:** None.

### Withdraw a queued round from the iPad

**What:** Let the designer take back a round that is still `queued`: stored on the Mac but not yet handed to Claude Code. A Withdraw action on the iPad; the round ends in a new final status, `withdrawn`, and is never delivered.

**Why:** Once Send is tapped there is no way back. A sketch sent by mistake, or one made stale by the round before it, waits in the queue while Claude Code is busy or not running, and is then applied. Withdrawing is only safe while the round is `queued`; once it is `sent`, Claude Code already has it. Owner request, 2026-10-09, after device testing.

**Context:** Needs a design decision first: where the action lives, now that the iPad has no list of rounds (2026-10-13; the send chip is the one place a sent round still shows), what a withdrawn round shows as, and whether its strokes come back to the canvas. Then three pieces. An additive iPad-to-Mac control message naming the `annotationId` (PROTOCOL.md section 11.2; no `pv` bump). A daemon endpoint that marks a round withdrawn only if it has not been claimed or served, so it cannot race the delivery: status is derived today in `DesignCanvas/server/src/store/rounds.ts` from `servedAt` and `reply`, and `RoundStatus` gains the value in `server/src/shared.ts` and `DesignCanvas/Shared/CanvasMessages.swift`. The action itself in the iPad chrome, `DesignCanvas/iOS/CanvasScreen.swift`. Check how an iPad app from before the change decodes a status it does not know. Shares the "never emit this round" path with Pending-round TTL above.

**Effort:** M
**Priority:** Not set
**Depends on:** A design decision.

### `annotationAck` so the iPad clears strokes only once the Mac accepted the job

**What:** An additive `annotationAck {ok, reason?}` control message, sender to receiver: the Mac sends it once an `annotation` has been queued for upload (or refused), and the iPad leaves SENDING on that rather than on its own socket write completing.

**Why:** "Sent" on the iPad means the socket write finished (plan ruling 5), which is not the same as the Mac having taken the round. The final-review fix for C1 closes the common case — a link drop no longer loses the held freeze capture, and a re-sent `annotation` is deduplicated by its `t` — but if the Mac *app itself* restarts between Done and the re-send, the parked capture is gone with it: the iPad shows the sketch as sent and no round ever appears. An ack is the only way to make "sent" mean "accepted".

**Context:** Deferred by the controller in the final fix wave (final-fix-findings.md, C1) to keep that wave free of new wire messages. Start at PROTOCOL.md section 11.2 (the message table) and 11.1 (the capability gate); then `DrawModeStateMachine` (a `.acked`/`.rejected` event beside `.sent`), `CanvasModel.sendAnnotation`, and `CanvasSession.handleAnnotation`, which is where accept/refuse is already decided. Additive, so no `pv` bump.

**Effort:** M
**Priority:** P2
**Depends on:** None.

### Frame ring per-frame cost (I6)

**What:** Measure what `FrameRing`'s deep copy costs the capture path on real hardware, then reduce it: a `CVPixelBufferPool` instead of a fresh `CVPixelBufferCreate` per frame, the copy moved off the sender's queue, and `CVBufferPropagateAttachments` so the copy keeps the source's attachments.

**Why:** The ring copies every captured frame, at capture rate, on the sender's serial queue — the queue that also feeds the encoder. The cost is unmeasured, and a per-frame allocation plus a row-by-row memcpy of a full-resolution frame is exactly the kind of work that shows up as dropped frames on a 4K display.

**Context:** Reviewed as I6 in the final fix wave and deferred for want of a measurement: the numbers decide whether any of this is worth the complexity. Measure frame drops (`MacSender`'s `drops`/`encDrops` counters, already on the `ping`) with and without a canvas delegate injected, on hardware, before changing anything. `DesignCanvas/Mac/Engine/FrameRing.swift`, `deepCopy(_:)`.

**Effort:** M
**Priority:** P2
**Depends on:** A hardware measurement run.

### `Compositor.composite` re-encodes the full screenshot on every round

**What:** Make `CompositeResult.screenshotPNG` lazy — produced only when the upload path actually needs it — instead of encoding it inside `composite`.

**Why:** Every round PNG-encodes the full, uncropped frame as well as the composite, and the result is used only when the freeze's own capture post failed or the daemon has lost the capture. That is a full-resolution encode per sketch spent on a path that is normally not taken.

**Context:** Noticed in the final whole-branch review and deferred as a performance-only change. `DesignCanvas/Mac/Engine/Compositor.swift` (`composite`, `CompositeResult`) and its one consumer, `UploadPipeline.runAnnotation`. The image work already runs off the sender's queue, so this is about CPU, not about the invariant.

**Effort:** S
**Priority:** P3
**Depends on:** None.

### Daemon log rotation

**What:** Rotate `~/Library/Logs/DesignCanvas/server.log` — size-based, keeping a bounded number of previous files.

**Why:** The log is append-only with no bound. The final fix wave removed the worst producer (the 2 s health poll is no longer logged, I5), which makes the growth slow rather than fast; a long-running daemon still grows it for ever.

**Context:** Deferred by the controller in the final fix wave (final-fix-findings.md, I5). `DesignCanvas/server/src/log.ts` is the single writer, so this is one function; the store's own sweeps (`pruneCaptures`) are the precedent for where to schedule it.

**Effort:** S
**Priority:** P3
**Depends on:** None.

### Cross-language contract test in CI

**What:** A test that runs the real built daemon and drives it with the Swift `DaemonClient` — capture, annotation, rounds, the rounds stream — so the two sides of the loopback API are checked against each other rather than against each other's fakes.

**Why:** Every request and response shape is asserted twice, once in `DaemonClientTests` against a stubbed `URLProtocol` and once in the Node tests against a stubbed client. Both can be right while the two disagree: the multipart body, the status codes, the `createdAt` format and the SSE framing are all only ever tested against a copy of the other side.

**Context:** Deferred by the controller in the final fix wave. The pieces exist: `server/scripts/e2e-round.mjs` already stands a real daemon up, and the CI workflow (`.github/workflows/tests.yml`) already runs both toolchains. The missing piece is a hostless Swift test target that may talk to a local port, which the current test bundle deliberately avoids.

**Effort:** M
**Priority:** P3
**Depends on:** None.

### Kept strokes are not re-anchored when the video rect changes

**What:** Re-anchor (or explicitly drop) the strokes kept in the sketch canvas when the rect the picture covers at scale 1 changes between Draw Mode entries — a rotation, a resolution change on the Mac. Zoom is no longer a cause: since 2026-10-09 strokes are stored relative to the unzoomed view and zoomed together with the video (technical_doc.md section 3).

**Why:** Strokes survive leaving Draw Mode by cancel, rotation, link loss or a refused freeze (M6, M7, PRD G6), and the canvas is one object that is never rebuilt. After a rotation, or a resolution change on the Mac, those strokes are still at their old points on a surface that now maps to a different part of the frame, so they land somewhere they were not drawn.

**Context:** Noticed in the final whole-branch review and deferred: what *should* happen is a design question (scale them, offset them, or warn and clear). `DesignCanvas/iOS/SketchCanvas.swift` (the controller owns the `PKCanvasView` and its `drawing`; the host view lays it out) and `ZoomModel.sketchRect`.

**Effort:** M
**Priority:** P3
**Depends on:** A design decision.

### Oversize-sketch notice is not visible in Draw Mode

**What:** Show the `sketchTooLarge` notice while Draw Mode is open, for example by rendering the notice banner over the Draw Mode chrome.

**Why:** When a sketch would exceed the 16 MiB canvas frame cap, `CanvasModel.done` correctly refuses to send it, keeps the strokes and sets the notice. But `CanvasScreen` renders the notice banner only outside Draw Mode, and the connection sheet that also shows it is out of reach in Draw Mode. So Send on an oversize sketch looks like a dead button.

**Context:** Found by the scoped re-review of the final fix wave (2026-09-17) as the one finding left partially addressed; parked because the process allows no second fix wave, nothing else builds on it, and the trigger (a sketch PNG over 15 MiB) is rare. Start at `DesignCanvas/iOS/CanvasScreen.swift`, where the chrome decides when `NoticeBanner` shows; the model side is already tested (`test_done_withAnOversizeSketch_staysInDrawingAndSaysSo`).

**Effort:** S
**Priority:** P2
**Depends on:** None.

### Parked freeze captures expire only when fetched

**What:** Sweep expired entries out of `CanvasCaptureParkingLot`, either on every `park` or on a timer.

**Why:** A device that freezes once and never returns leaves a full-resolution frame retained for the life of the Mac app. The 10-minute expiry is only evaluated when the same device asks for its capture.

**Context:** Minor from the scoped re-review of the final fix wave (2026-09-17). Start at `DesignCanvas/Mac/Engine/CanvasCaptureParkingLot.swift`.

**Effort:** S
**Priority:** P3
**Depends on:** None.

### Claude Code mod: follow-ups from Claude Code 2.1.290 to 2.1.292

From a read of the Claude Code changelog on 2026-10-06. Backlog only, not prioritized (owner, 2026-10-06). The mod was built and tested on 2.1.289; it passes `claude plugin validate --strict` on 2.1.292 and has not been run live on anything newer than 2.1.289. Context for all of these: `technical_doc-ClaudeMods.md`.

**Re-run the live checks on the current Claude Code.** One session against a scratch daemon: a round end to end, the permission wait, a daemon restart, a session ended mid-round. Three releases changed how hooks behave while the hooks worker restarts and how a mod's prompts are queued. **Effort:** S

**Limit the sketch-read approval to the main session.** `tool.check` carries `agentId` since 2.1.290. X7 approves the read of the current round's composite whoever asks; with `agentId` it can decline to approve for a subagent. Treat the field as optional so the minimum stays 2.1.287. **Effort:** S

**Respect an organisation's approval ceiling in the sketch-read approval.** `tool.check` reports `ceiling` since 2.1.290, the approval an organisation requires for a tool. X7 should return the decision unchanged when a ceiling asks for a prompt. Optional field, as above. **Effort:** S

**Give the mod's gating hooks a `.catch`.** Since 2.1.290 `claude plugin validate --json` lists each hook at a gating site with `hasCatch`; all of the mod's (`tool.call`, `tool.check`, the three `classic.*` hooks) report false. They guard themselves inside the hook body, but a `.catch` is the documented way to say what happens when one throws or times out, and what should happen differs: fail open for the reply tool and the waiting tracker, fail to "ask" for the read approval. **Effort:** S

**Use `claude plugin install --marketplace` for the published mod.** Added in 2.1.292: adds the marketplace if needed and installs from it in one command. It is the mechanism for the marketplace half of the every-session option (XG7), in place of the `CLAUDE_CODE_PLUGIN_DIRS` entry. **Depends on:** the marketplace listing. **Effort:** M

**Channel baseline: expect a slower first connect.** Since 2.1.292 local MCP servers negotiate protocol version 2026-07-28 by default, and a server that ignores the check is connected the older way after one slow attempt. The channel uses an older MCP SDK. When the reply-compliance baseline is run on the channel, allow for that or set `MCP_PROTOCOL_NEGOTIATION=legacy`, and record which. **Effort:** none beyond the run

**Phase 2: approving the call does not answer a question.** Since 2.1.292 a `tool.check` hook that answers "allow" no longer skips the dialog of a tool that needs the user's own answer (a question, a plan approval). X13's answer-from-the-iPad cannot be built by approving the call; it has to supply the answer. Note for the Phase 2 design, nothing to do now.

## Completed

### Tool panel covers the bottom band of the frozen frame

Done 2026-10-13 with the iPad redesign. The panel docks to the top by default, sits in the top bar in Draw Mode where the screen is wide enough, and can be dragged, or moved from a long-press menu, to any screen edge, where it stays (PRD P4).

### `.mcp.json` carries absolute machine-specific paths

Done with the Claude Code mod (2026-10-05, `technical_doc-ClaudeMods.md`). Sketches reach Claude Code through the mod, `McpConfigManager` is gone, and nothing is written to a project's `.mcp.json` any more. An old `design-canvas` entry left there by an earlier build is not touched; since the plugin was renamed `designcanvas` it no longer stops the mod.
