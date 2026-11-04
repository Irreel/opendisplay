# TODOS

## Design Canvas

### Pair by typing a code, not only comparing one

**What:** Let the iPad show a code that is typed on the Mac (as AirPlay and HomeKit do), inside a password-authenticated key exchange (SPAKE2 or SRP), as an alternative to comparing the code on both screens.

**Why:** Pairing since 2026-11-03 (`wire-protocol.md` section 5.7) compares a six-digit code on both screens, which is safe without a PAKE but asks for a tap on both devices. A typed code is one action, but safe only inside a PAKE, and CryptoKit has none, so it needs a vetted implementation.

**Context:** `Shared/Pairing.swift` (the pairing exchange), `Mac/App/PairingPanel.swift`, the iPad's alert in `CanvasScreen.swift`. Pairing also gates the permission relay on the iPad (the Claude Code Channels reference requires an authenticated sender), which is now possible. Eng review 2026-09-16, decision 3A.

**Effort:** M
**Priority:** P3
**Depends on:** None.

### Authenticate the daemon's loopback API

**What:** A per-launch secret the Mac app gives the daemon and the mod (a 0600 file under the app's support folder, or the launch environment for sessions it starts), sent as a bearer token on every request and checked both ways: the daemon refuses requests without it, and the mod refuses a daemon that cannot show it.

**Why:** The daemon trusts every process on the Mac (README, "Residual risk"). Anything local can register a session, make itself the target (`wasTarget`), and receive the iPad's sketches, or answer on the daemon's port first and hand the mod rounds of its own. Since 2026-11-03 the mod approves a sketch Read only for a composite whose real path is in the store's own layout, so a fake daemon can no longer have it read an arbitrary file unprompted; it can still inject sketches and notes. (The Mac-iPad link is paired and encrypted since the same day; this hop is the one left open.)

**Context:** Raised by the automated security review on 2026-11-03. Start at `server/src/http/server.ts` (the sessions routes) and `mod/hooks/register.js` (`call`, `registerSession`). A session the user started by hand has no launch environment, so the mod needs a file it can read through `$.fs`.

**Effort:** M
**Priority:** P2
**Depends on:** None.

### `annotationAck` so the iPad clears strokes only once the Mac accepted the job

**What:** An additive `annotationAck {ok, reason?}` control message, sender to receiver: the Mac sends it once an `annotation` has been queued for upload (or refused), and the iPad leaves SENDING on that rather than on its own socket write completing.

**Why:** "Sent" on the iPad means the socket write finished (plan ruling 5), which is not the same as the Mac having taken the round. The final-review fix for C1 closes the common case — a link drop no longer loses the held freeze capture, and a re-sent `annotation` is deduplicated by its `t` — but if the Mac *app itself* restarts between Done and the re-send, the held capture is gone with it: the iPad shows the sketch as sent and no round ever appears. An ack is the only way to make "sent" mean "accepted".

**Context:** Deferred by the controller in the final fix wave (final-fix-findings.md, C1) to keep that wave free of new wire messages. Start at `wire-protocol.md` section 6 (the message table); then `DrawModeStateMachine` (a `.acked`/`.rejected` event beside `.sent`), `CanvasModel.sendAnnotation`, and `CanvasSession.handleAnnotation`, which is where accept/refuse is already decided. A wire change both apps ship together.

**Effort:** M
**Priority:** P2
**Depends on:** None.

### Frame ring per-frame cost (I6)

**What:** Measure what the frame ring's deep copy costs the capture path on real hardware, then reduce it: a `CVPixelBufferPool` instead of a fresh `CVPixelBufferCreate` per frame, the copy moved off the stream queue, and `CVBufferPropagateAttachments` so the copy keeps the source's attachments.

**Why:** The ring copies every frame handed to an encoder (once, however many iPads encode it), on the stream queue — the queue that also feeds the encoders. The cost is unmeasured, and a per-frame allocation plus a row-by-row memcpy of a full-resolution frame is exactly the kind of work that shows up as dropped frames on a 4K display.

**Context:** Reviewed as I6 in the final fix wave and deferred for want of a measurement: the numbers decide whether any of this is worth the complexity. Time `CleanFrameStore.keep` on hardware, and count how often a link's latest-frame mailbox replaces a waiting frame, before changing anything. `DesignCanvas/Mac/Engine/FrameRing.swift`, `deepCopy(_:)`; `Mac/Stream/MirrorLink.swift`, `submit`.

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

### Held freeze captures expire only when used

**What:** Drop a `CanvasSession`'s held freeze capture once it has expired, on a timer or when the iPad's link drops for good, instead of only when an `annotation` arrives.

**Why:** An iPad that freezes once and never returns leaves a full-resolution frame retained for the life of the Mac app. The 10-minute expiry (`CanvasSession.heldCaptureExpiry`) is only evaluated when the same iPad sends its sketch. (Until 2026-11-03 the frame waited in a parking lot with the same flaw; sessions now live per iPad and hold it themselves.)

**Context:** Minor from the scoped re-review of the final fix wave (2026-09-17). Start at `DesignCanvas/Mac/Engine/CanvasSession.swift`, `handleFreeze` and `handleAnnotation`.

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

### The every-session switch rewrites the whole settings file

**What:** Turn the every-session option on and off with a text-level edit of `~/.claude/settings.json` that touches only the one `env` entry and leaves the rest of the file as the user wrote it.

**Why:** Today the content after on-then-off is identical key for key, but `JSONSerialization` re-sorts the top-level keys and reformats the file. For a file people edit by hand that is more than the "one entry" the Settings window promises.

**Context:** Found on the Mac on 2026-10-06 (technical_doc-ClaudeMods.md section 13). The write is in `DesignCanvas/Mac/App/ClaudeSettingsManager.swift`.

**Effort:** S
**Priority:** Not set
**Depends on:** None.

### The Mac menu's buttons have no accessibility names

**What:** Give every button in the menu-bar popover, the session rows included, an accessibility label.

**Why:** VoiceOver and UI scripting see only the rows' help text, so the controls cannot be named or found by what they do.

**Context:** Found on the Mac on 2026-10-06 (technical_doc-ClaudeMods.md section 13). Start at `DesignCanvas/Mac/App/MenuBarView.swift`.

**Effort:** S
**Priority:** Not set
**Depends on:** None.

### The iPad shows in the Mac menu as "iPhone / iPad"

**What:** Find why the menu names a USB-connected iPad "iPhone / iPad" instead of its device name, as earlier builds did, and fix it.

**Why:** With more than one device the rows cannot be told apart.

**Context:** Seen on the Mac on 2026-10-06, not traced, with the OpenDisplay-based sender. Since 2026-11-03 the menu names a cabled iPad by its lockdown name, then the name in its hello, then its Bonjour name, and falls back to "iPad" (`MirrorEngine.publish`, `VisibleDevice.name`); whether usbmuxd's name lookup (`UsbmuxDeviceWatcher.resolveName`) is what fails is still to be seen on hardware.

**Effort:** S
**Priority:** Not set
**Depends on:** None.

## Completed

### Tool panel covers the bottom band of the frozen frame

Done 2026-10-13 with the iPad redesign. The panel docks to the top by default, sits in the top bar in Draw Mode where the screen is wide enough, and can be dragged, or moved from a long-press menu, to any screen edge, where it stays (PRD P4).

### `.mcp.json` carries absolute machine-specific paths

Done with the Claude Code mod (2026-10-05, `technical_doc-ClaudeMods.md`). Sketches reach Claude Code through the mod, `McpConfigManager` is gone, and nothing is written to a project's `.mcp.json` any more. An old `design-canvas` entry left there by an earlier build is not touched; since the plugin was renamed `designcanvas` it no longer stops the mod.
