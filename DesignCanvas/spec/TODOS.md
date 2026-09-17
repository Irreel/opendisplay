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

### Tool panel covers the bottom band of the frozen frame

**What:** Decide where Draw Mode's tool panel lives so it stops sitting over the frame being annotated — a side rail, a collapsible bar, or a panel that fades while a stroke is in progress.

**Why:** The panel floats over the bottom of the mirror in Draw Mode, so anything in that band cannot be drawn on without moving it out of the way first. The sketch surface is the whole video rect, so the strokes underneath the panel would be fine — the designer just cannot reach them.

**Context:** A design decision, not a bug, so the final fix wave left it alone. `DesignCanvas/iOS/CanvasScreen.swift` (the `chrome` layer) and `DrawModeOverlay.swift`.

**Effort:** S
**Priority:** P3
**Depends on:** A design decision.

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

### `.mcp.json` carries absolute machine-specific paths

**What:** Stop committing machine-specific paths in the `design-canvas` entry: resolve the node binary and the server entry at spawn time (a wrapper script in the repo, a user-scoped MCP config, or an entry that runs `npx`/a checked-in launcher).

**Why:** The entry is written as `{command: <the node path this Mac resolved>, args: [<this checkout's dist/index.js>, "--channel"]}` and `.mcp.json` is a committed, project-scoped file. A collaborator who pulls it inherits an entry naming paths that do not exist on their machine, and Claude Code will try to spawn it. Since M9 this app at least *recognizes* a foreign entry and offers to rewrite it rather than accepting it, which makes the failure explicit instead of silent — it does not make the committed file portable.

**Context:** Plan ruling 8 chose the ai.cst.2 behaviour deliberately for the MVP; the final review recorded the consequence. `DesignCanvas/Mac/App/McpConfigManager.swift`, and `AppModel.startSession()` which supplies the two paths.

**Effort:** M
**Priority:** P2
**Depends on:** None.

### Kept strokes are not re-anchored when the video rect changes

**What:** Re-anchor (or explicitly drop) the strokes kept in the sketch canvas when the rect the video covers on screen changes between Draw Mode entries — a zoom, a rotation, a resolution change on the Mac.

**Why:** Strokes survive leaving Draw Mode by cancel, rotation, link loss or a refused freeze (M6, M7, PRD G6), and the canvas is one object that is never rebuilt. If the designer zooms in before entering again, those strokes are still at their old points on a surface that now maps to a different part of the frame, so they land somewhere they were not drawn.

**Context:** Noticed in the final whole-branch review and deferred: what *should* happen is a design question (scale them, offset them, or warn and clear). `DesignCanvas/iOS/SketchCanvas.swift` (the controller owns the `PKCanvasView` and its `drawing`), `CanvasScreen.videoRect`, and `ZoomModel`.

**Effort:** M
**Priority:** P3
**Depends on:** A design decision.

## Completed
