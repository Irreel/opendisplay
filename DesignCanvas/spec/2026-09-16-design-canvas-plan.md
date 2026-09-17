# Design Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task, and superpowers:test-driven-development inside every task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Design Canvas (Mac menu-bar app + iPad app + local Node daemon/channel) inside this repo, so a sketch drawn on a live iPad mirror is pushed into a running Claude Code session and the outcome is shown back on the iPad.

**Architecture:** Design Canvas is a separate pair of apps built on OpenDisplay's sender and receiver code. All new code lives under `DesignCanvas/`. OpenDisplay's own files get only small, inert-by-default hooks (a control-frame policy, an input-sink factory, a canvas delegate, a configurable discovery type). A Node daemon (loopback only) owns the store; a Node channel process speaks MCP to Claude Code; the Mac app's in-process engine joins the iPad wire to the daemon.

**Tech Stack:** Swift 5.9 (SwiftUI, AppKit, UIKit, PencilKit, ScreenCaptureKit, Network.framework), XcodeGen (`project.yml`), XCTest hostless bundles, Node >= 20.10 + TypeScript + `node:test` + `tsx`, `@modelcontextprotocol/sdk`.

**Spec:** `DesignCanvas/spec/technical_doc.md` (binding), `DesignCanvas/spec/PRD-DesignCanvas.md`, `DesignCanvas/spec/TODOS.md`. Wire base: `PROTOCOL.md`, `COMPATIBILITY.md`.

**Prior art to copy from (read-only, never modify):** `/Users/zhao/Documents/Project_current/ai.cst.2` — `packages/server`, `packages/shared`, `apps/desktop`, `apps/ipad`. Same owner as this project; relicensed GPL-3.0 here by owner decision (technical_doc.md section 7).

## Global Constraints

- **Folder rule.** Every new Design Canvas file lives under `DesignCanvas/`. The only files outside it that may change are the ones a task lists by name (`Mac/`, `Shared/`, `iOS/`, `MacTests/`, `project.yml`, `.gitignore`, `PROTOCOL.md`, `.github/workflows/tests.yml`). A new file goes in `Mac/` or `Shared/` only when OpenDisplay's own targets must compile it.
- **OpenDisplay must not change behaviour.** Every hook added to an OpenDisplay file is inert unless a Design Canvas object is injected. After every task that touches `Mac/`, `Shared/`, `iOS/` or `project.yml`, all of these must pass: OpenSidecarMac tests, OpenSidecarMacReceiver build, OpenSidecariOS build (commands below).
- **`Shared/` stays Foundation/SwiftUI-only and compiles at macOS 12** (the receiver target's floor). No UIKit/AppKit there.
- **Never edit `OpenSidecar.xcodeproj`.** Change `project.yml`, then run `./generate.sh`. The project file and generated `Info.plist` files are gitignored.
- **Wire rules (PROTOCOL.md).** Frames are `[4-byte big-endian length][payload]` both ways. Canvas messages are additive JSON, no `pv` bump, gated on `welcome.canvas: true`. Sender-to-receiver JSON must be shorter than 32768 bytes, start with `{`, contain no NUL byte. Unknown types and fields are ignored.
- **No input forwarding on a canvas session.** No `touch`, `scroll`, `pencil`, `proximity` is sent by the iPad or acted on by the Mac. The Design Canvas Mac target does not compile `Mac/InputInjector.swift` and never calls any Accessibility API. Screen Recording is the only TCC grant.
- **Exact values.** Canvas receiver-to-sender frame cap 16 MiB (16777216); non-canvas cap 1 MiB (1048576); chunk size 256 KiB (262144); sender-to-iPad JSON limit 32768 bytes (exclusive); `agentReply.message` at most 2048 UTF-8 bytes on the wire; composite long side at most 1568 px; rounds snapshot = last 20 rounds per device; freeze timeout 2 s; claim lease 30 s; backlog replay 1 per second; daemon port 47100 on `127.0.0.1` only; health poll 2 s; iPad listens on TCP 9100 (UDP cursor 9101); Bonjour type `_designcanvas._tcp`; store root `~/.claude/channels/design-canvas/`; meta schema version 3; channel name `design-canvas`; reply tool name `design_canvas_reply`; reply statuses `applied | failed | needs_input`; round statuses `queued | sent | applied | failed | needs_input`.
- **Invariants from ai.cst.2.** The daemon is the only writer to the store. An annotation's files are immutable once written; only `meta.json` state changes. Only `DesignCanvas/server/src/channel/` imports the MCP SDK. No Design Canvas code calls an LLM or edits user source. Every request, push, reply and state change is logged as JSON lines.
- **Logging discipline.** No unthrottled `Log.info` on per-frame paths. Per-message canvas logs (freeze, annotation, reply) are fine; per-frame ring activity is never logged.
- **Identity.** Product name `Design Canvas` (Debug: `Design Canvas Dev`). Bundle ids `com.designcanvas.mac` (Debug `com.designcanvas.mac.debug`), `com.designcanvas.ipad` (Debug `com.designcanvas.ipad.debug`). License GPL-3.0.
- **TDD.** No production code without a failing test first. Each task's report must show RED output then GREEN output. UI-only SwiftUI/UIKit view code that cannot be unit-tested is kept thin: logic lives in a pure struct or view-model that is tested, and the view is verified by a successful build.
- **Commits.** Conventional Commits, small, one per green cycle or logical step. Stage files by explicit path; never `git add -A` or `git add .`. End each commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

### Verification commands (run from the repo root)

```sh
# Regenerate after any project.yml change
./generate.sh

# Filter used below
F='error:|warning:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|BUILD (SUCCEEDED|FAILED)|failed -'

# OpenDisplay regression gate
xcodebuild test  -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"
xcodebuild build -project OpenSidecar.xcodeproj -scheme OpenSidecarMacReceiver -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"
xcodebuild build -project OpenSidecar.xcodeproj -scheme OpenSidecariOS -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"

# Design Canvas Swift tests (scheme created in Task 1)
xcodebuild test -project OpenSidecar.xcodeproj -scheme DesignCanvas -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"
# One class:  add  -only-testing:DesignCanvasTests/<ClassName>

# Design Canvas apps (targets created in Tasks 10 and 12)
xcodebuild build -project OpenSidecar.xcodeproj -scheme DesignCanvasMac -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"
xcodebuild build -project OpenSidecar.xcodeproj -scheme DesignCanvasiOS -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "$F"

# Node (package created in Task 6)
pnpm --dir DesignCanvas/server install
pnpm --dir DesignCanvas/server test
pnpm --dir DesignCanvas/server typecheck
```

A harmless `IDETesting: Result bundle saving failed ... chmod: Operation not permitted` line appears after `TEST SUCCEEDED` in this environment. It is sandbox noise, not a failure.

## File Structure

```
DesignCanvas/
  README.md                         Task 13: what it is, build, run, onboarding, LAN risk
  spec/                             PRD, technical spec, TODOS, this plan
  Shared/                           Foundation-only; compiled into DC Mac, DC iOS, DC tests
    CanvasMessages.swift            wire structs, constants, truncation, rounds snapshot encoding
    DrawModeStateMachine.swift      pure Draw Mode state machine
  Mac/
    Engine/                         in-process engine; hostless-testable
      FrameRing.swift               ring of clean frames keyed by capture ms
      Compositor.swift              crop, flatten, cap, PNG encode
      DaemonClient.swift            HTTP + SSE loopback client (DaemonAPI protocol)
      CanvasSession.swift           per-device join: freeze, annotation, rounds, replies
    App/                            menu-bar shell (ported from ai.cst.2 apps/desktop)
      DesignCanvasMacApp.swift  AppModel.swift  MenuBarView.swift  SenderEngine.swift
      DaemonSupervisor.swift  ClaudeLauncher.swift  McpConfigManager.swift
      SessionStateClassifier.swift  DisplayStateCopy.swift  ProcessResetService.swift
      ProjectRecents.swift  ScreenRecordingPermission.swift
    DesignCanvasMac.entitlements
  iOS/
    DesignCanvasApp.swift  CanvasScreen.swift  CanvasModel.swift  ZoomModel.swift
    CanvasVideoView.swift  DrawModeOverlay.swift  SketchCanvas.swift
    AgentRepliesView.swift  ConnectionStatusView.swift
    DesignCanvasiOS.entitlements
  Tests/                            hostless XCTest bundle `DesignCanvasTests`
  server/                           Node package: daemon (--http) + channel (--channel)
    package.json  tsconfig.json  scripts/run-tests.mjs  scripts/channel-harness.mjs  scripts/e2e-round.mjs
    src/index.ts  src/log.ts  src/shared.ts
    src/http/{server,identity,multipart,event-stream,rounds-stream}.ts
    src/store/{store,paths,uuidv7,rounds}.ts
    src/channel/{index,subscriber,reply-tool}.ts

Touched OpenDisplay files (hooks only):
  Mac/ControlFramePolicy.swift      NEW  frame cap + chunk plan + outbound JSON guard (Task 2)
  Mac/SenderCanvasHooks.swift       NEW  InputSink, SenderCanvasDelegate, CanvasOutbound, SenderControlJSON (Task 3)
  Mac/SenderController.swift        NEW  SenderController, DeviceSession, ConnectionTarget moved out of the app file (Task 4)
  Mac/MacSender.swift               read loop, send guard, hooks
  Mac/InputInjector.swift           conforms to InputSink
  Mac/OpenSidecarMacApp.swift       loses the moved types; passes OpenDisplay config
  Shared/Protocol.swift             canvas WireMessage constants
  Shared/StreamReceiver.swift       service type + port config, canvas callbacks, freeze, canvas sends (Task 11)
  iOS/ReceiverModel.swift           NEW  ReceiverModel moved out of the app file (Task 11)
  iOS/OpenSidecarPhoneApp.swift     loses ReceiverModel
  MacTests/                         tests for the new Mac/ pure logic
  project.yml  .gitignore  PROTOCOL.md  .github/workflows/tests.yml
```

## Rulings made while planning

These resolve gaps or conflicts in the spec. Each is binding for implementers.

1. **Separate port.** The Design Canvas iPad listens on TCP 9100, not 9000. USB dialing has no Bonjour type, so without this an OpenDisplay sender would dial a Design Canvas iPad. This extends the spec's "do not dial each other" intent to USB.
2. **Message truncation happens in the daemon, not the channel.** The spec says both "the channel truncates before the daemon" and "the full text stays in the store". The channel posts the full text; the daemon stores it in full and truncates to 2048 UTF-8 bytes in everything it emits (`/v1/rounds`, the rounds stream).
3. **Rounds snapshot must fit 32 KiB.** 20 rounds with 2 KB messages can exceed the sender-to-iPad limit. The encoder shrinks in steps: full; then messages and notes cut to 256 bytes; then oldest rounds dropped until it fits.
4. **Live status uses one message.** `agentReply.status` carries all five round statuses (`queued`, `sent`, `applied`, `failed`, `needs_input`) so the iPad can show queued and sent without polling. The daemon emits a `round.updated` event on create, served, and reply; the engine relays each as `agentReply`.
5. **"Sent" on the iPad means the socket write completed.** There is no wire ack for `annotation`. A link loss before completion moves Draw Mode to RETRY and the sketch is resent after the next `hello`.
6. **Ring size is a frame count, not 2 s.** Deep copies of 120 full frames would cost hundreds of MB. The ring keeps the last 16 frames (a static screen keeps its last frame indefinitely because nothing evicts it). Lookup tolerance is 34 ms; outside it `frozen.ok` is `false`.
7. **Strokes may start during FREEZING.** The freeze round trip is milliseconds and M7 requires strokes to survive a failed freeze, so the canvas accepts input at once; Done stays disabled until DRAWING.
8. **Server entry is user-selected, as in ai.cst.2.** The app does not bundle Node. It resolves `node` from the login shell and remembers the path to `DesignCanvas/server/dist/index.js`; `.mcp.json` gets `{command: <node>, args: [<entry>, "--channel"]}`.
9. **Deferred, recorded in the README:** custom app icons (G18 is open), Sparkle wiring and appcast (no feed exists yet), the release pipeline, Metal rendering on the iPad (the layer path makes freeze trivial), redo and clear-all (G6 open), and device-level E2E (needs hardware; a checklist ships instead).

---

### Task 1: Shared wire types, Draw Mode state machine, and the test target

**Files:**
- Create: `DesignCanvas/Shared/CanvasMessages.swift`, `DesignCanvas/Shared/DrawModeStateMachine.swift`
- Create: `DesignCanvas/Tests/CanvasMessagesTests.swift`, `DesignCanvas/Tests/DrawModeStateMachineTests.swift`
- Modify: `project.yml` (new target `DesignCanvasTests`, new scheme `DesignCanvas`), `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces (exact names; later tasks depend on them). All types are `internal`, Foundation-only, and use `[String: Any]` JSON dictionaries because both wire ends use `JSONSerialization`.

```swift
enum CanvasWire {
    static let freeze = "freeze", frozen = "frozen", annotation = "annotation"
    static let agentReply = "agentReply", rounds = "rounds"
    static let welcomeCanvasKey = "canvas"            // welcome.canvas: true
    static let pingChannelKey = "channel", pingProjectKey = "project"
    static let senderJSONLimit = 32768                // payload must be < this
    static let replyMessageMaxBytes = 2048
    static let roundsSnapshotLimit = 20
    static let shrunkTextMaxBytes = 256
}
struct NormalizedRect: Equatable {                    // unit square, origin top-left
    var x, y, width, height: Double
    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    var isFull: Bool                                  // within 0.001 of .full
    func clamped() -> NormalizedRect                  // into [0,1], min size 0.01, never empty
    init?(json: Any?)                                 // {"x","y","w","h"} numbers
    var json: [String: Double]                        // {"x","y","w","h"}
}
struct CanvasViewport: Equatable { var width: Int; var height: Int; var scale: Double
    init?(json: Any?); var json: [String: Any] }      // {"w","h","scale"}
enum RoundStatus: String { case queued, sent, applied, failed, needsInput = "needs_input" }
enum ChannelState: String { case attached, detached, none }
struct FreezeMessage: Equatable { var captureMs: Int64; var zoomRect: NormalizedRect; var t: Double
    init?(json: [String: Any]); var json: [String: Any] }
struct FrozenMessage: Equatable { var ok: Bool; init?(json: [String: Any]); var json: [String: Any] }
struct AnnotationMessage: Equatable { var sketchPNG: Data; var zoomRect: NormalizedRect
    var viewport: CanvasViewport; var note: String?; var t: Double
    init?(json: [String: Any]); var json: [String: Any] }   // "sketch" is base64
struct AgentReplyMessage: Equatable { var annotationId: String; var status: RoundStatus
    var message: String?; var prUrl: String?; var t: Double
    init?(json: [String: Any]); var json: [String: Any] }
struct CanvasRound: Equatable { var annotationId: String; var createdAt: String; var status: RoundStatus
    var message: String?; var prUrl: String?; var note: String?
    init?(json: [String: Any]); var json: [String: Any] }
struct RoundsMessage: Equatable { var rounds: [CanvasRound]          // newest first
    init?(json: [String: Any]); var json: [String: Any]
    /// JSON bytes guaranteed < limit, shrinking per ruling 3. Never returns nil: worst case is an empty list.
    func encoded(limit: Int = CanvasWire.senderJSONLimit) -> Data }
extension String { func truncatedUTF8(maxBytes: Int) -> String }   // cuts on a Character boundary, appends nothing

struct DrawModeStateMachine {
    enum State: Equatable { case live, freezing(deadline: TimeInterval), drawing, sending, retry }
    enum Event: Equatable { case enterDrawMode(now: TimeInterval), frozen(ok: Bool), tick(now: TimeInterval)
        case strokeCountChanged(Int), done, cancel, discard, sent, linkLost, rotated, helloReceived }
    enum Notice: Equatable { case noFrame, freezeTimedOut, interruptedByRotation, interruptedByLinkLoss }
    enum Effect: Equatable { case pauseSync, resumeSync, sendFreeze, sendAnnotation, clearStrokes, show(Notice) }
    static let freezeTimeout: TimeInterval = 2
    private(set) var state: State = .live
    private(set) var strokeCount = 0
    var canSend: Bool                 // state == .drawing && strokeCount > 0
    var isInDrawMode: Bool            // .freezing or .drawing
    mutating func handle(_ event: Event) -> [Effect]
}
```

**Transition table (complete; any pair not listed returns `[]` and leaves state unchanged):**

| State | Event | New state | Effects |
|---|---|---|---|
| live | enterDrawMode(now) | freezing(deadline: now + 2) | pauseSync, sendFreeze |
| freezing | frozen(ok: true) | drawing | — |
| freezing | frozen(ok: false) | live | resumeSync, show(.noFrame) |
| freezing | tick(now) with now >= deadline | live | resumeSync, show(.freezeTimedOut) |
| freezing, drawing | cancel | live | resumeSync |
| freezing, drawing | discard | live | resumeSync, clearStrokes |
| freezing, drawing | rotated | live | resumeSync, show(.interruptedByRotation) |
| freezing, drawing | linkLost | live | resumeSync, show(.interruptedByLinkLoss) |
| drawing | done, strokeCount >= 1 | sending | sendAnnotation, resumeSync |
| sending | sent | live | clearStrokes |
| sending | linkLost | retry | — |
| retry | helloReceived | sending | sendAnnotation |
| any | strokeCountChanged(n) | unchanged | — (records `strokeCount = max(0, n)`) |

Strokes are kept (no `clearStrokes`) on cancel, rotation, link loss, failed freeze and timeout. `enterDrawMode` is ignored outside `live`. `done` with zero strokes is ignored.

**Required test cases.** `DrawModeStateMachineTests`: one test per table row; plus `tick` before the deadline does nothing; second `enterDrawMode` while freezing and while drawing is ignored; `done` with zero strokes is ignored; `canSend` false in freezing even with strokes; full happy path live→freezing→drawing→sending→live; retry path sending→retry→sending→live; `frozen` arriving in `live` is ignored. `CanvasMessagesTests`: each message round-trips `init?(json:)`/`json`; each returns nil when a required field is missing or mistyped; unknown extra fields are ignored; `AnnotationMessage` rejects invalid base64; numbers arriving as `Int` or `Double` both decode (`JSONSerialization` gives `NSNumber`); `NormalizedRect.clamped` handles negative origin, overflow past 1, zero and negative size; `isFull`; `truncatedUTF8` with ASCII, with a multi-byte character straddling the limit (emoji), with `maxBytes` 0, with a string already short enough; `RoundsMessage.encoded`: small list unchanged and parses back equal; 20 rounds with 2048-byte messages yields data `< 32768` with messages cut to 256 bytes; 20 rounds whose ids/URLs alone overflow drops oldest (last elements) until it fits; output always starts with `{` and contains no NUL byte.

- [ ] **Step 1: Add the test target and scheme.** In `project.yml` add under `schemes:`

```yaml
  DesignCanvas:
    build:
      targets:
        DesignCanvasTests: [test]
    test:
      targets:
        - DesignCanvasTests
```

and under `targets:`

```yaml
  DesignCanvasTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - DesignCanvas/Tests
      - DesignCanvas/Shared
    settings:
      base:
        TEST_HOST: ""
        BUNDLE_LOADER: ""
        GENERATE_INFOPLIST_FILE: "YES"
        PRODUCT_BUNDLE_IDENTIFIER: com.designcanvas.tests
```

Append to `.gitignore`: `DesignCanvas/server/dist/`, `DesignCanvas/Mac/Info.plist`, `DesignCanvas/iOS/Info.plist`, `.superpowers/`.

- [ ] **Step 2: Write `DrawModeStateMachineTests.swift` first** (all cases above), plus a stub-free empty `DesignCanvas/Shared/` so the target generates. Run `./generate.sh` then the Design Canvas test command. Expected RED: compile errors naming `DrawModeStateMachine`.
- [ ] **Step 3: Implement `DrawModeStateMachine.swift`** minimally. Run tests. Expected GREEN.
- [ ] **Step 4: Commit** `feat(canvas): add Draw Mode state machine and DesignCanvas test target`.
- [ ] **Step 5: Write `CanvasMessagesTests.swift`.** Run. Expected RED: unresolved identifiers.
- [ ] **Step 6: Implement `CanvasMessages.swift`.** Run. Expected GREEN, no warnings.
- [ ] **Step 7: Run the OpenDisplay regression gate** (three commands). Expected: unchanged results (34 tests pass, two builds succeed).
- [ ] **Step 8: Commit** `feat(canvas): add canvas wire messages with size-safe rounds encoding`.

---

### Task 2: Control frame policy, chunked control reads, and the outbound JSON guard

Fixes the spec's frame-length finding: today `Mac/MacSender.swift` `receiveControl` rejects a receiver-to-sender frame of 1 MiB or more with a bare `return`, which never re-arms the read, so all control input silently stops while video continues.

**Files:**
- Create: `Mac/ControlFramePolicy.swift`, `MacTests/ControlFramePolicyTests.swift`
- Modify: `Mac/MacSender.swift` (`receiveControl(on:)` near line 1645; `sendJSONFrame(_:)` near line 2232), `project.yml` (add `Mac/ControlFramePolicy.swift` to `OpenSidecarMacTests` sources)

**Interfaces:**
- Produces:

```swift
struct ControlFramePolicy: Equatable {
    static let standardCap = 1 << 20          // 1 MiB
    static let canvasCap = 16 << 20           // 16 MiB
    static let chunkSize = 256 << 10          // 256 KiB
    static let outboundJSONLimit = 32768
    let cap: Int                               // declared length must be 1 ..< cap
    init(canvas: Bool)
    enum Decision: Equatable { case read(chunks: [Int]), reject(reason: String) }
    /// length <= 0 or >= cap -> .reject; otherwise chunk sizes that sum to length, each <= chunkSize, last may be smaller.
    func decide(declaredLength: Int) -> Decision
    /// true iff 0 < byteCount < outboundJSONLimit
    static func allowsOutboundJSON(byteCount: Int) -> Bool
}
```

**Behaviour required in `MacSender`:**
1. `receiveControl` reads the 4-byte header as today, then asks `controlFramePolicy.decide`. On `.reject`: `Log.info("control frame rejected: <reason> (declared <n> bytes)")` then `linkDied("oversize or empty control frame")`, only when `self.connection === conn`. It must never return without either re-arming the read or killing the link.
2. On `.read(chunks:)`: read the chunks sequentially with `conn.receive(minimumIncompleteLength: n, maximumLength: n)`, appending to one buffer. After **each** chunk set `lastReceived = Date()` so the 5 s watchdog sees bytes flowing during a slow upload. A receive error or short read mid-payload follows the same error path the header read uses today (log, skip own-cancel `ECANCELED`, `linkDied`).
3. When the payload is complete, **re-arm first** (`receiveControl(on: conn)`), then call `handleControl(payload)`. This ordering is a spec requirement so later heavy canvas work can never block pings.
4. `controlFramePolicy` is a stored `var` initialised to `ControlFramePolicy(canvas: false)`. Task 3 switches it for canvas sessions. Add no canvas logic here.
5. `sendJSONFrame` checks `ControlFramePolicy.allowsOutboundJSON(byteCount:)`; on failure it logs `refusing oversize control message (<n> bytes, type <type-or-unknown>)` and returns without sending. Extract the `type` cheaply (a regex or a prefix scan), never by parsing a huge payload.

**Required test cases** (`ControlFramePolicyTests`): cap is 1 MiB without canvas, 16 MiB with; lengths 0 and -1 rejected; `cap - 1` accepted and `cap` rejected for both modes; a 1-byte frame is one 1-byte chunk; exactly 256 KiB is one chunk; 256 KiB + 1 is two chunks `[262144, 1]`; a 1 MiB - 1 frame's chunks sum to the length and none exceeds 256 KiB; the 16 MiB - 1 canvas frame yields 64 chunks; `allowsOutboundJSON` false for 0, true for 1 and 32767, false for 32768.

- [ ] **Step 1:** Write `ControlFramePolicyTests.swift`; add the source path to `OpenSidecarMacTests` in `project.yml`; `./generate.sh`; run OpenSidecarMac tests. Expected RED: unresolved `ControlFramePolicy`.
- [ ] **Step 2:** Implement `Mac/ControlFramePolicy.swift`. Run. Expected GREEN.
- [ ] **Step 3:** Commit `feat(mac): add ControlFramePolicy for control frame caps and chunking`.
- [ ] **Step 4:** Rewrite `receiveControl` and guard `sendJSONFrame` per the behaviour list. Keep every existing comment that still applies. Run the full OpenDisplay regression gate. Expected: 34 + new tests pass, builds succeed, no new warnings.
- [ ] **Step 5:** Self-check by reading the new read loop once for each exit path: header error, reject, chunk error, success. Each must end in exactly one of re-arm or `linkDied` (own-cancel excepted). Record the four paths and their line numbers in the report.
- [ ] **Step 6:** Commit `fix(mac): chunked control reads that never stall; refuse oversize control JSON`.

---

### Task 3: Sender hooks — input sink factory, canvas delegate, welcome and ping fields

Makes `MacSender` usable by Design Canvas without `InputInjector` and lets an injected delegate see captured frames and canvas messages. With nothing injected, OpenDisplay behaves exactly as before.

**Files:**
- Create: `Mac/SenderCanvasHooks.swift`, `MacTests/SenderControlJSONTests.swift`
- Modify: `Mac/MacSender.swift`, `Mac/InputInjector.swift`, `Mac/OpenSidecarMacApp.swift` (the single `MacSender(...)` construction site), `Shared/Protocol.swift`, `project.yml` (add `Mac/SenderCanvasHooks.swift` to `OpenSidecarMacTests`)

**Interfaces:**
- Consumes: `ControlFramePolicy(canvas:)` from Task 2.
- Produces (`Mac/SenderCanvasHooks.swift`; imports Foundation, CoreVideo, CoreGraphics only; must not reference `MacSender`, `PhoneInfo`, or any Design Canvas type):

```swift
/// What MacSender needs from an input injector. InputInjector conforms; Design Canvas passes none.
protocol InputSink: AnyObject {
    func handleTouch(phase: String, x: Double, y: Double)
    func handleScroll(dx: Double, dy: Double)
    func handlePencil(phase: String, x: Double, y: Double, pressure: Double, azimuth: Double, altitude: Double, rotation: Double)
    func handleProximity(entering: Bool, x: Double, y: Double)
}
typealias InputSinkFactory = (CGDirectDisplayID) -> InputSink?

/// The sender side a canvas delegate may talk back to. MacSender conforms.
protocol CanvasOutbound: AnyObject {
    /// Serialises and sends on the sender's queue. Returns false (and logs) if not connected,
    /// not serialisable, or the payload breaks the 32768-byte rule.
    @discardableResult func sendCanvasJSON(_ object: [String: Any]) -> Bool
    /// Same, for bytes already encoded (used for the size-fitted rounds snapshot).
    @discardableResult func sendCanvasJSONData(_ data: Data) -> Bool
}

struct CanvasPeer: Equatable { let installID: String; let deviceKind: String }

/// All callbacks arrive on the sender's serial queue. Implementations must return quickly.
protocol SenderCanvasDelegate: AnyObject {
    func canvasPeerDidHello(_ peer: CanvasPeer, outbound: CanvasOutbound)      // after welcome was sent
    func canvasDidEncodeFrame(_ pixelBuffer: CVPixelBuffer, captureMs: Int64)   // same ms as the frame's "cap"
    func canvasDidReceive(type: String, object: [String: Any], outbound: CanvasOutbound)
    func canvasLinkDidDrop()
    func canvasPingFields() -> [String: String]                                 // e.g. ["channel": "attached", "project": "site"]
}

enum SenderControlJSON {
    static func welcome(pv: Int, min: Int, canvas: Bool) -> String     // canvas key present only when true
    static func ping(drops: Int, encDrops: Int, netDrops: Int, pending: Int,
                     inp50: Double, inp95: Double, capFps: Int, extras: [String: String]) -> String
}
```

- `Shared/Protocol.swift`: add to `WireMessage` the constants `freeze`, `frozen`, `annotation`, `agentReply`, `rounds` with direction comments, matching Task 1's strings. (Design Canvas code uses `CanvasWire`; these document the wire for OpenDisplay readers and are used by `MacSender`'s switch.)

**Behaviour required in `MacSender`:**
1. `init` gains two trailing defaulted parameters: `inputSinkFactory: InputSinkFactory? = nil`, `canvasDelegate: SenderCanvasDelegate? = nil` (stored; delegate held `weak`). `inputInjector` becomes `InputSink?`; the two construction sites call `inputSinkFactory?(vd.displayID)`. `MacSender.swift` must no longer name the type `InputInjector`.
2. The OpenDisplay construction site passes `inputSinkFactory: { InputInjector(displayID: $0) }` so behaviour is unchanged. `InputInjector` gains `: InputSink` (its methods already match; adjust labels only if the compiler requires).
3. In `start()`, the Accessibility wait (`AXIsProcessTrusted` loop) runs only when `inputSinkFactory != nil`.
4. When `canvasDelegate != nil` ("canvas session"): `controlFramePolicy = ControlFramePolicy(canvas: true)`; `welcome` carries `"canvas":true`; inbound `touch`, `scroll`, `pencil`, `proximity` are dropped without calling the sink; inbound `freeze` and `annotation` go to `canvasDidReceive`; after every `hello` (once `sendWelcome()` ran) call `canvasPeerDidHello` with `CanvasPeer(installID: info.id ?? "", deviceKind: info.kind)`; `linkDied`, `reportGone` and `stop()` call `canvasLinkDidDrop()`; the sender's outbound `ping` merges `canvasPingFields()`.
5. In `encode(_:pts:generation:)`, right after `capturedAtMs` is computed and only when a delegate exists, call `canvasDidEncodeFrame(pixelBuffer, captureMs: capturedAtMs)`.
6. `welcome` and `ping` strings are built by `SenderControlJSON`. With `canvas: false` and empty `extras` the output must be **byte-identical** to today's hand-built strings.
7. `MacSender` conforms to `CanvasOutbound`. `sendCanvasJSON` serialises with `JSONSerialization` and hops to `queue` before calling `sendJSONFrame` (it may be called from any thread). Returns false for non-serialisable objects.
8. Without a delegate, `freeze` and `annotation` fall through to the existing unknown-type log policy.

**Required test cases** (`SenderControlJSONTests`): `welcome(pv: 3, min: 1, canvas: false)` equals exactly `{"type":"welcome","pv":3,"min":1}`; with `canvas: true` it parses as JSON with `canvas == true` and the same `pv`/`min`; `ping` with empty extras equals exactly the legacy format string for given numbers (copy the legacy interpolation from `schedulePing` into the test as the expected value); `ping` with extras parses as JSON and contains both string fields plus every numeric field; an extra containing a quote, a backslash and a newline still yields valid JSON that round-trips the value; extras are emitted in sorted key order (deterministic); an extra whose key collides with a built-in field (`"type"`, `"drops"`) is ignored.

- [ ] **Step 1:** Write `SenderControlJSONTests.swift`, register `Mac/SenderCanvasHooks.swift` in `OpenSidecarMacTests`, `./generate.sh`, run. Expected RED.
- [ ] **Step 2:** Implement `Mac/SenderCanvasHooks.swift`. Run. Expected GREEN.
- [ ] **Step 3:** Commit `feat(mac): add sender canvas hook protocols and control JSON builders`.
- [ ] **Step 4:** Apply behaviours 1–3 (input sink). Run the regression gate. Commit `refactor(mac): inject the input sink into MacSender`.
- [ ] **Step 5:** Apply behaviours 4–8 and the `Shared/Protocol.swift` constants. Run the regression gate (all three; `Shared/` changed). Verify `grep -n "InputInjector" Mac/MacSender.swift` prints nothing.
- [ ] **Step 6:** Commit `feat(mac): canvas delegate hooks in MacSender (inert without a delegate)`.

---

### Task 4: Extract `SenderController` with injectable discovery and session configuration

Design Canvas reuses OpenDisplay's connection policy (USB auto-connect, WiFi trust-on-first-use, dedupe, cable upgrade). Those live in `SenderController`, which today sits inside the app file next to `@main` and OpenDisplay's views.

**Files:**
- Create: `Mac/SenderController.swift`, `MacTests/SenderControllerConfigTests.swift`
- Modify: `Mac/OpenSidecarMacApp.swift`, `project.yml` (no change needed for `OpenSidecarMac`, which compiles all of `Mac/`)

**Interfaces:**
- Consumes: `InputSinkFactory`, `SenderCanvasDelegate` (Task 3).
- Produces:

```swift
struct SenderControllerConfig {
    var bonjourType: String = "_opensidecar._tcp"
    var devicePort: UInt16 = 9000                       // USB dial port and the default WiFi port
    var inputSinkFactory: InputSinkFactory? = nil
    /// Called on the main actor when a session is created; the returned delegate is retained by the DeviceSession.
    var canvasDelegateFactory: (@MainActor (DeviceSession) -> SenderCanvasDelegate?)? = nil
    /// Called on the main actor whenever `presentation` changes (OpenDisplay shows its main window here).
    var onPresentationChanged: (@MainActor (AppPresentation) -> Void)? = nil
}
// In Mac/OpenSidecarMacApp.swift (NOT in SenderController.swift, which must not name InputInjector):
// extension SenderControllerConfig { static var openDisplay: SenderControllerConfig }   // factory = { InputInjector(displayID: $0) }
```

**Requirements:**
1. Move `ConnectionTarget`, `DeviceSession`, `SenderController`, and `AppPresentation` verbatim into `Mac/SenderController.swift`. `@main`, `AppDelegate`, `MainWindow`, `PermissionMonitor`, `ContentView`, `SessionRow` stay in `OpenSidecarMacApp.swift`.
2. `SenderController` gets `init(config: SenderControllerConfig)`. `static let shared` stays in an `extension SenderController` inside `OpenSidecarMacApp.swift`, built from a config whose `onPresentationChanged` does what the `presentation` `didSet` does today with `MainWindow`. After the move, `Mac/SenderController.swift` must not reference `MainWindow`, `ContentView`, `PermissionMonitor`, `InputInjector`, or Sparkle.
3. `config.bonjourType` replaces the literal in `startBrowsing()`; `config.devicePort` replaces the literal 9000 default for USB dialing and the `port` default string. Persisted `UserDefaults` keys are unchanged.
4. `DeviceSession` gains `var canvasDelegate: SenderCanvasDelegate?` (strong). In `connect(to:…)`, the session and sender are created so the delegate exists before `sender.start()`: build the `DeviceSession`, ask `canvasDelegateFactory`, pass the result and `config.inputSinkFactory` into `MacSender(...)`. If `DeviceSession` currently requires the sender at init, make `sender` an implicitly-set `private(set) var` assigned immediately after; do not change any other behaviour.
5. No behaviour change for OpenDisplay. Moved code is moved, not rewritten: `git diff --stat` should show the app file shrinking by about what the new file gains.

**Required test cases** (`SenderControllerConfigTests`, hostless): the default config has `_opensidecar._tcp`, port 9000, nil factories. If `SenderControllerConfig` cannot compile hostlessly because it references `DeviceSession`/`AppPresentation`, split the pure defaults into `struct SenderDiscoveryConfig { bonjourType; devicePort }` nested in the config, keep that struct in its own small file `Mac/SenderDiscoveryConfig.swift`, and test that instead; record which route was taken.

- [ ] **Step 1:** Write the config test, register its source file(s) in `OpenSidecarMacTests`, run. Expected RED.
- [ ] **Step 2:** Add the config type(s). Run. Expected GREEN. Commit `feat(mac): add sender controller configuration`.
- [ ] **Step 3:** Move the types and wire the config (requirements 1–4). Run the full regression gate. Expected: all pass, no new warnings.
- [ ] **Step 4:** Verify with grep that `Mac/SenderController.swift` contains none of: `MainWindow`, `ContentView`, `PermissionMonitor`, `InputInjector`, `Sparkle`, `"_opensidecar._tcp"` (the literal now lives only in the config default).
- [ ] **Step 5:** Commit `refactor(mac): extract SenderController with injectable discovery and session hooks`.

---

### Task 5: Frame ring and compositor

**Files:**
- Create: `DesignCanvas/Mac/Engine/FrameRing.swift`, `DesignCanvas/Mac/Engine/Compositor.swift`
- Create: `DesignCanvas/Tests/FrameRingTests.swift`, `DesignCanvas/Tests/CompositorTests.swift`, `DesignCanvas/Tests/TestImages.swift` (helpers)
- Modify: `project.yml` (`DesignCanvasTests` sources add `DesignCanvas/Mac/Engine`, `Mac/Log.swift`, `Mac/LogPolicies.swift`, and the setting `SWIFT_OBJC_BRIDGING_HEADER: Mac/OpenSidecarMac-Bridging-Header.h`, as `OpenSidecarMacTests` does, so engine code may call `Log.info`)

**Interfaces:**
- Consumes: `NormalizedRect` (Task 1).
- Produces:

```swift
/// Not thread-safe: owned by one queue. Stores deep copies so ScreenCaptureKit's buffer pool is never starved.
struct FrameRing {
    static let defaultCapacity = 16
    static let defaultToleranceMs: Int64 = 34
    init(capacity: Int = FrameRing.defaultCapacity)
    var count: Int { get }
    mutating func append(_ pixelBuffer: CVPixelBuffer, captureMs: Int64)     // deep-copies; evicts oldest beyond capacity
    /// Exact match wins; else the nearest entry with |delta| <= toleranceMs; else nil. Ties pick the older frame.
    func frame(at captureMs: Int64, toleranceMs: Int64 = FrameRing.defaultToleranceMs) -> (pixelBuffer: CVPixelBuffer, captureMs: Int64)?
    mutating func removeAll()
    static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer?            // handles planar (NV12) and BGRA
}

enum CompositorError: Error, Equatable { case undecodableSketch, emptyBase, encodeFailed }
struct CompositeResult { let compositePNG: Data; let sketchPNG: Data; let screenshotPNG: Data
                         let compositeSize: CGSize; let cropRectPixels: CGRect }
enum Compositor {
    static let maxLongSide = 1568
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage?           // VTCreateCGImageFromCVPixelBuffer
    static func pngData(_ image: CGImage) -> Data?
    /// zoomRect is clamped; .isFull means no crop. The sketch is stretched over the crop, the result is
    /// scaled so its long side <= maxLongSide (never upscaled). screenshotPNG is the full uncropped base.
    /// An empty sketch (zero bytes) means "no strokes": composite == crop. Undecodable non-empty bytes throw.
    static func composite(base: CGImage, sketchPNG: Data, zoomRect: NormalizedRect) throws -> CompositeResult
}
```

**Required test cases.** `TestImages` builds solid and quadrant-coloured `CGImage`s and BGRA/NV12 `CVPixelBuffer`s and reads a pixel's RGBA from PNG data. `FrameRingTests`: empty ring returns nil; exact match; nearest within 34 ms; 35 ms away returns nil; tie prefers older; capacity 16 evicts the oldest (17 appends, first is gone, count 16); the stored buffer is a copy (mutate the source after append, stored pixel unchanged) for BGRA and for NV12; `removeAll`. `CompositorTests` (pixel-level): full rect on a 400×300 base keeps size 400×300 and base colours; a red opaque sketch pixel region overrides the base there and transparent sketch areas show the base; zoomRect = right half of a left-blue/right-green base gives an all-green 200×300 composite; a 4000×2000 base is scaled to 1568×784; a 100×50 base is not upscaled; zoomRect partly outside (x: 0.8, w: 0.5) is clamped, no crash, width is 20% of the base; empty sketch data gives composite equal to the crop; garbage sketch bytes throw `.undecodableSketch`; `screenshotPNG` always decodes to the full base size; `sketchPNG` in the result is the input bytes unchanged.

- [ ] **Step 1:** Add the source path to `project.yml`, `./generate.sh`. Write `TestImages.swift` and `FrameRingTests.swift`. Run. Expected RED.
- [ ] **Step 2:** Implement `FrameRing.swift`. Run. Expected GREEN. Commit `feat(canvas): add frame ring keyed by capture time`.
- [ ] **Step 3:** Write `CompositorTests.swift`. Run. Expected RED.
- [ ] **Step 4:** Implement `Compositor.swift` (CoreGraphics + ImageIO + VideoToolbox; sRGB; top-left origin handled explicitly since CoreGraphics is bottom-left). Run. Expected GREEN.
- [ ] **Step 5:** Commit `feat(canvas): add Mac compositor with zoom crop and size cap`.

---

### Task 6: Daemon — port from ai.cst.2, loopback only, schema v3, replies and rounds

**Files:**
- Create: `DesignCanvas/server/` — `package.json`, `tsconfig.json`, `README.md`, `scripts/run-tests.mjs`, `src/index.ts`, `src/log.ts`, `src/shared.ts`, `src/http/{server,identity,multipart,event-stream,rounds-stream}.ts`, `src/store/{store,paths,uuidv7,rounds}.ts`, `src/channel/{index,subscriber}.ts` (channel files copied unchanged here; Task 7 changes them), and `*.test.ts` beside each module.
- Source to copy from: `/Users/zhao/Documents/Project_current/ai.cst.2/packages/server` and `packages/shared/src/index.ts` (becomes `src/shared.ts`; replace every `@design-canvas/shared` import with a relative import). Copy `pnpm-lock` nothing; run a fresh `pnpm install` inside `DesignCanvas/server`.

**Package setup:** name `@design-canvas/server`, `"private": true`, `"type": "module"`, `"license": "GPL-3.0-only"`, `bin: { designtool: "./dist/index.js" }`, scripts `build: tsc`, `typecheck: tsc --noEmit`, `test: node scripts/run-tests.mjs` (runs `node --import tsx --test` over `src/**/*.test.ts`, as in ai.cst.2), `test:channel`, `start`. Dependencies: `@modelcontextprotocol/sdk ^1.29.0`; drop `zod` unless the SDK import requires it at compile time. Dev: `tsx`, `typescript`, `@types/node`. `tsconfig.json` inlines ai.cst.2's `tsconfig.base.json` options (strict, `exactOptionalPropertyTypes`, `verbatimModuleSyntax`, `rootDir: src`, `outDir: dist`). The package is standalone: no workspace file, nothing added to the repo-root `package.json`.

**Interfaces — Produces (HTTP on `127.0.0.1:47100`; every endpoint answers 403 `{error:"forbidden"}` to a non-loopback peer):**

| Method and path | Request | Success | Errors |
|---|---|---|---|
| GET `/v1/health` | — | 200 `{status:"ok", version, channelAttached, pid, instanceId, startedAt, serverEntry, port, channelCount, channelAttachedAt}` | — |
| POST `/v1/captures` | JSON `{screenshotBase64, viewport:{w,h}, createdAt?}` or multipart `meta` + `screenshot` | 201 `{captureId}` | 400 `invalid_request`, 413 |
| POST `/v1/annotations` | multipart: `meta` (JSON below), `composite` (PNG), `sketch` (PNG); or JSON with `compositeBase64`, `sketchBase64` and the same meta fields | 201 `{annotationId, dispatched}` | 400 `invalid_request`, 404 `capture_not_found`, 413 |
| GET `/v1/annotations` | — | 200 `{annotations: AnnotationMeta[]}` | — |
| POST `/v1/annotations/:id/claim` | — | 200 `{meta, compositePath, capturedAt}` | 409 `already_claimed`, 404 |
| POST `/v1/annotations/:id/served` | — | 200 `{meta}` | 404 `annotation_not_found` |
| POST `/v1/annotations/:id/reply` | JSON `{status, message?, prUrl?}` | 200 `{meta}` | 400 `invalid_request` (bad status, non-string fields), 404, 409 `already_replied` |
| DELETE `/v1/annotations/:id` | — | 200 `{deleted:true}` | 404 |
| GET `/v1/annotations/stream` | — | SSE `event: annotation.pending`, `data: <id>` (channel processes; counted in `channelCount`) | — |
| GET `/v1/rounds?device=<id>&limit=<n>` | `limit` default 20, max 20 | 200 `{rounds: Round[]}` newest first | 400 when `device` is missing |
| GET `/v1/rounds/stream` | — | SSE `event: round.updated`, `data: <JSON RoundEvent>` (engine; **not** counted in `channelCount`) | — |

```ts
// annotation upload meta
{ sourceCaptureId: string, viewport: {w:number,h:number,scale?:number}, zoomRect: {x,y,w,h}|null,
  note?: {text?: string|null}, device: {id: string, name: string}, createdAt?: string }
// src/shared.ts additions
export const SCHEMA_VERSION = 3;
export const REPLY_STATUSES = ['applied','failed','needs_input'] as const;
export const REPLY_MESSAGE_MAX_BYTES = 2048;
export const ROUNDS_LIMIT = 20;
export type RoundStatus = 'queued'|'sent'|'applied'|'failed'|'needs_input';
export interface AnnotationReply { status: ReplyStatus; message: string|null; prUrl: string|null; at: string }
export interface AnnotationMeta { id; schemaVersion; createdAt; claimedAt: string|null; servedAt: string|null;
  viewport: Viewport; zoomRect: ZoomRect|null; note: AnnotationNote; sourceCaptureId: string;
  device: {id: string; name: string}; reply: AnnotationReply|null }
export interface Round { annotationId; createdAt; status: RoundStatus; message?: string; prUrl?: string; note?: string }
export interface RoundEvent extends Round { deviceId: string }
// src/store/rounds.ts (pure)
export function roundStatus(meta: AnnotationMeta): RoundStatus            // reply?.status ?? (servedAt ? 'sent' : 'queued')
export function truncateUtf8(text: string, maxBytes: number): string       // never splits a code point
export function toRound(meta: AnnotationMeta): Round                       // message truncated to 2048 bytes; omits absent fields
// src/store/uuidv7.ts
export function uuidv7(nowMs?: number): string                             // RFC 9562 layout, lexically time-sortable
```

**Requirements:**
1. Bind `127.0.0.1` only. Remove the `host` option and `SERVER_HOST`; remove CORS headers, `ipadUrls`, `pairedDevices`, `GET /v1/captures/latest`, `GET /v1/captures/:id/screenshot.png`, the pairing path constants, `sourceLabel`, and the v1 `pageUrl` shim.
2. Store root default `~/.claude/channels/design-canvas/` (env override `DESIGN_CANVAS_STORE_DIR` stays for tests). Log default `~/Library/Logs/DesignCanvas/server.log` (override `DESIGN_CANVAS_LOG_PATH`).
3. Annotation ids are `uuidv7()`. Capture ids keep the existing sortable id.
4. `createAnnotation` writes `composite.png`, `sketch.png`, copies the capture's `screenshot.png` into the annotation directory, and writes `meta.json` (schema 3). An unknown `sourceCaptureId` fails with 404 and writes nothing.
5. A v2 `meta.json` on disk still reads: `sourceLabel` ignored, `device` defaults to `{id:"",name:""}`, `zoomRect` and `reply` default to `null`.
6. `setReply(id, reply)` runs under the per-id lock, stores the **full** message, sets `at`, and refuses a second reply (409). The reply is independent of claim state and may arrive before or after `served`.
7. `claim` returns `capturedAt` = the source capture's `createdAt` (falls back to the annotation's `createdAt` when the capture is gone).
8. A second bus, `RoundsEventBus`, emits a `RoundEvent` when an annotation is created (`queued`), marked served (`sent`), and replied. Reconcile-to-pending emits nothing.
9. Every request, response, claim, served, reply, and reconcile is logged as a JSON line, as ai.cst.2 does; add `annotation.replied`.
10. Removing `sourceLabel` breaks the copied `src/channel/index.ts`. In this task make only the minimal edit there that keeps `typecheck` green: delete the `Source:` line and the `source_label` meta key. Task 7 rewrites the notification properly.

**Required tests (`node:test`, temp-dir store + `port: 0` + silent logger, as in ai.cst.2).** Port the seven ai.cst.2 test files first, adapting payloads to schema 3, then add: server address is `127.0.0.1`; a request whose socket is non-loopback gets 403 (unit-test the guard function with a fake `remoteAddress`); health has no `ipadUrls`/`pairedDevices`; `captures/latest` is 404; annotation upload happy path writes four files and schema 3 meta with `device` and `zoomRect`; unknown capture → 404 and no directory created; v2 record reads with defaults; reply happy path stores full 5000-byte message, second reply → 409, bad status → 400, unknown id → 404, reply before served works; `uuidv7` matches `/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/` and two ids from increasing timestamps sort ascending; `truncateUtf8` with ASCII, with an emoji straddling the limit, with limit 0; `roundStatus` for all five outcomes; `/v1/rounds` filters by device, is newest first, caps at 20 with 25 stored, truncates the message to at most 2048 bytes, 400 without `device`; rounds stream delivers `queued`, `sent`, then `applied` events in order with the right `deviceId`; opening the rounds stream leaves `channelCount` at 0; claim response carries `capturedAt`.

- [ ] **Step 1:** Scaffold `package.json`, `tsconfig.json`, `scripts/run-tests.mjs`; `pnpm --dir DesignCanvas/server install`. Copy the ai.cst.2 **test files only**, fix imports. Run `pnpm --dir DesignCanvas/server test`. Expected RED: modules not found.
- [ ] **Step 2:** Copy the ai.cst.2 sources, create `src/shared.ts`, fix imports. Run. Expected: ported tests GREEN (before any behaviour change). Commit `feat(canvas-server): port daemon and channel from ai.cst.2`.
- [ ] **Step 3:** For each requirement group — (a) loopback-only and removals, (b) paths and uuidv7, (c) schema 3 upload with screenshot copy and v2 read, (d) reply endpoint, (e) rounds pure functions, `/v1/rounds`, rounds stream, (f) `capturedAt` on claim — write the failing tests, watch them fail for the right reason, implement, watch them pass. One commit per group, `feat(canvas-server): …`.
- [ ] **Step 4:** `pnpm --dir DesignCanvas/server typecheck` and `build` are clean. `git status` shows no `dist/` or `node_modules/` staged. Commit any leftovers.

---

### Task 7: Channel — reply tool, notification text, harness

**Files:**
- Create: `DesignCanvas/server/src/channel/reply-tool.ts`, `reply-tool.test.ts`, `index.test.ts`, `DesignCanvas/server/scripts/channel-harness.mjs` (ported from ai.cst.2 `packages/server/scripts/channel-harness.mjs`)
- Modify: `DesignCanvas/server/src/channel/index.ts`, `subscriber.ts`, `subscriber.test.ts`

**Interfaces:**
- Consumes: `POST /v1/annotations/:id/reply`, claim's `capturedAt` (Task 6).
- Produces:

```ts
// reply-tool.ts — no MCP SDK import here; pure and unit-testable
export const REPLY_TOOL = { name: 'design_canvas_reply', description: string, inputSchema: {
  type: 'object', required: ['annotation_id','status'], additionalProperties: false, properties: {
    annotation_id: {type:'string'}, status: {type:'string', enum:['applied','failed','needs_input']},
    message: {type:'string'}, pr_url: {type:'string'} } } } as const;
export type ReplyArgs = { annotationId: string; status: ReplyStatus; message?: string; prUrl?: string };
export function parseReplyArgs(raw: unknown): ReplyArgs | { error: string };
export type PostReply = (args: ReplyArgs) => Promise<{ ok: true } | { ok: false; status: number; code: string }>;
export async function handleReplyCall(raw: unknown, post: PostReply):
  Promise<{ content: [{type:'text', text: string}]; isError?: true }>;
// index.ts
export interface ClaimedAnnotation { meta: AnnotationMeta; compositePath: string; capturedAt: string }
export function createInstructionText(a: ClaimedAnnotation): string;       // exported for tests
export function createMcpChannel(logger: Logger, options?: { transport?: Transport; postReply?: PostReply; baseUrl?: string }): ChannelNotifier;
```

**Requirements:**
1. Capabilities: `experimental: {'claude/channel': {}}` and `tools: {}`. Register `ListTools` (returns exactly `[REPLY_TOOL]`) and `CallTool` handlers (unknown tool name → `isError`).
2. Notification `content` is exactly (spec 5.3):

```
New annotation from iPad.
Annotation ID: <id>
Device: <device name, or "unknown iPad" when empty>
Captured at: <capturedAt>
Sent at: <meta.createdAt>
Composite PNG path: <absolute compositePath>
Zoom region: <"full frame" when zoomRect is null, else "x=0.250 y=0.100 w=0.500 h=0.400" with 3 decimals>
Note: <trimmed note text or "(none)">

Inspect the composite PNG path to see the visual annotation.
Apply this annotation to the source code, then call design_canvas_reply with the outcome.
```

   `meta` is exactly `{source: 'design-canvas', annotation_id, device}`.
3. Server `instructions`: events arrive as `<channel source="design-canvas" ...>`; read the composite PNG at the given path; apply the change to this project's source; then call `design_canvas_reply` exactly once per annotation with `applied`, `failed`, or `needs_input`, a short message, and `pr_url` when a pull request was opened.
4. `handleReplyCall`: invalid args → `isError` with the reason and no HTTP call; 200 → `"Reply recorded."`; 409 → `isError` `"A reply was already recorded for this annotation."`; 404 → `isError` `"Unknown annotation id."`; network failure → `isError` naming the daemon. The default `postReply` posts the **full** message to `baseUrl` (ruling 2). Nothing is sent back into Claude Code beyond the tool result.
5. Log `channel.reply.received` and `channel.reply.posted|failed`.
6. `subscriber.ts` passes `capturedAt` from the claim response through to `notifyAnnotation`.

**Required tests.** `reply-tool.test.ts`: `parseReplyArgs` accepts the minimal and full forms, rejects missing id, empty id, bad status, non-string message, extra keys are ignored; `handleReplyCall` for each outcome in requirement 4 using a fake `post` (assert it is not called on invalid args; assert the 5000-byte message is passed through untruncated). `index.test.ts` using the SDK's `InMemoryTransport.createLinkedPair()` and a `Client`: `listTools` returns one tool named `design_canvas_reply` with the enum; `callTool` reaches the injected `postReply` with mapped camelCase args; `notifyAnnotation` delivers a `notifications/claude/channel` notification whose `content` equals the template for a zoomed and for a full-frame annotation and whose `meta` has exactly the three keys; empty device name renders `unknown iPad`. Update `subscriber.test.ts` for the new claim shape.
**Harness** (`pnpm --dir DesignCanvas/server test:channel`): builds `dist/`, starts `--http` on a free port with a temp store, starts `--channel` as a real stdio MCP peer, posts a capture and an annotation, asserts exactly one notification with the right id and with `Device:` and `Zoom region:` lines, asserts `servedAt` becomes non-null, then calls `design_canvas_reply` over MCP and asserts `/v1/rounds` reports `applied`. Exit code 0 on success, non-zero with a reason otherwise.

- [ ] **Step 1:** Write `reply-tool.test.ts`. Run. Expected RED. Implement `reply-tool.ts`. GREEN. Commit `feat(canvas-server): add design_canvas_reply tool logic`.
- [ ] **Step 2:** Write `index.test.ts`. RED. Change `index.ts` and `subscriber.ts`. GREEN. Commit `feat(canvas-server): channel declares the reply tool and the v3 notification`.
- [ ] **Step 3:** Port and extend the harness; run it; paste its output into the report. Commit `test(canvas-server): channel harness covers notification payload and reply`.
- [ ] **Step 4:** Confirm with grep that `@modelcontextprotocol/sdk` is imported only under `src/channel/` and `scripts/`.

---

### Task 8: `DaemonClient` — one Swift client for health, uploads, rounds, and the rounds stream

**Files:**
- Create: `DesignCanvas/Mac/Engine/DaemonClient.swift`, `DesignCanvas/Mac/Engine/SSEParser.swift`
- Create: `DesignCanvas/Tests/DaemonClientTests.swift`, `DesignCanvas/Tests/SSEParserTests.swift`, `DesignCanvas/Tests/StubURLProtocol.swift`

**Interfaces:**
- Consumes: Task 6's HTTP contract; `CanvasRound`, `CanvasViewport`, `NormalizedRect`, `ChannelState` (Task 1).
- Produces:

```swift
struct DaemonHealth: Decodable, Equatable { let status: String; let version: String; let channelAttached: Bool
    let pid: Int?; let instanceId: String?; let startedAt: String?; let serverEntry: String?
    let port: Int?; let channelCount: Int?; let channelAttachedAt: String? }
enum HealthProbeResult: Equatable { case healthy(DaemonHealth), refused, timedOut, badStatus(Int), foreignResponse }
extension ChannelState { init(probe: HealthProbeResult) }   // healthy & count>0 -> .attached; healthy -> .detached; else .none
struct AnnotationUpload: Equatable { var sourceCaptureId: String; var compositePNG: Data; var sketchPNG: Data
    var viewport: CanvasViewport; var zoomRect: NormalizedRect?; var note: String?
    var deviceID: String; var deviceName: String; var createdAt: Date }
struct RoundUpdate: Equatable { let deviceID: String; let round: CanvasRound }
enum DaemonClientError: Error, Equatable { case badStatus(Int), undecodable, captureNotFound }
struct BackoffPolicy: Equatable { var minimum: TimeInterval = 0.5; var maximum: TimeInterval = 5
    mutating func next() -> TimeInterval      // 0.5, 1, 2, 4, 5, 5 …
    mutating func reset() }
protocol DaemonAPI: AnyObject {
    func probe() async -> HealthProbeResult
    func postCapture(png: Data, width: Int, height: Int) async throws -> String
    func postAnnotation(_ upload: AnnotationUpload) async throws -> String
    func rounds(deviceID: String, limit: Int) async throws -> [CanvasRound]
    func roundUpdates() -> AsyncStream<RoundUpdate>          // reconnects forever with backoff until the stream is cancelled
}
final class DaemonClient: DaemonAPI {
    init(baseURL: URL = URL(string: "http://127.0.0.1:47100")!,
         configuration: URLSessionConfiguration = .ephemeral,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
}
struct SSEEvent: Equatable { let event: String; let data: String }
struct SSEParser { mutating func feed(_ chunk: Data) -> [SSEEvent] }   // LF and CRLF, multi-line data joined with "\n", ignores comments and retry
```

**Requirements:** `probe()` uses a 1.5 s timeout and the ai.cst.2 outcome mapping (timeout → `.timedOut`; other transport errors → `.refused`; non-200 → `.badStatus`; 200 undecodable → `.foreignResponse`). `postCapture` sends JSON and expects 201. `postAnnotation` sends `multipart/form-data` with parts `meta`, `composite`, `sketch` and maps 404 `capture_not_found` to `.captureNotFound`. `rounds` builds `?device=&limit=` with proper percent-encoding. `roundUpdates` parses `round.updated` events into `RoundUpdate`, skips malformed ones, resets backoff after the first byte of a good connection.

**Required tests** (URLProtocol stub registered through `configuration.protocolClasses`; request bodies read from `httpBodyStream` when `httpBody` is nil): probe mapping for 200 good, 200 garbage, 500, timeout, connection refused; `ChannelState(probe:)` for each case; `postCapture` body fields and 201 parse, 500 throws `.badStatus(500)`; `postAnnotation` multipart contains the three named parts, the PNG bytes intact, and meta JSON with `device`, `zoomRect` (null when nil), `viewport`, `note.text`, ISO-8601 `createdAt`; 404 mapping; `rounds` query string and decode, including a device id with a space; `SSEParser` with an event split across chunks, CRLF input, multi-line data, comment lines, two events in one chunk; `roundUpdates` delivers an event from a first connection, reconnects after the stub closes it (the injected `sleep` records `0.5`), then delivers an event from the second connection; `BackoffPolicy` sequence and reset.

- [ ] **Step 1:** Write `SSEParserTests` and the `BackoffPolicy` tests. RED. Implement. GREEN. Commit `feat(canvas): add SSE parser and backoff policy`.
- [ ] **Step 2:** Write `StubURLProtocol.swift` and `DaemonClientTests`. RED. Implement `DaemonClient`. GREEN, no warnings. Commit `feat(canvas): add DaemonClient for the loopback daemon`.

---

### Task 9: `CanvasSession` and `CanvasHub` — the engine's join between the iPad wire and the daemon

**Files:**
- Create: `DesignCanvas/Mac/Engine/CanvasSession.swift`, `DesignCanvas/Mac/Engine/CanvasHub.swift`
- Create: `DesignCanvas/Tests/CanvasSessionTests.swift`, `DesignCanvas/Tests/CanvasHubTests.swift`, `DesignCanvas/Tests/CanvasFakes.swift`
- Modify: `project.yml` (`DesignCanvasTests` sources add `Mac/SenderCanvasHooks.swift`; `Mac/Log.swift` and the bridging header were added in Task 5)

**Interfaces:**
- Consumes: `SenderCanvasDelegate`, `CanvasOutbound`, `CanvasPeer` (Task 3); `FrameRing`, `Compositor` (Task 5); `DaemonAPI`, `AnnotationUpload`, `RoundUpdate`, `BackoffPolicy` (Task 8); message types (Task 1).
- Produces:

```swift
/// Thread-safe source of the two ping fields. The app updates it; sessions read it.
final class CanvasStatus { var channelState: ChannelState; var projectName: String?     // lock-protected
    var pingFields: [String: String] { get } }   // ["channel": …] plus "project" only when selected

final class CanvasSession: SenderCanvasDelegate {
    init(deviceName: String, daemon: DaemonAPI, status: CanvasStatus,
         workQueue: DispatchQueue = DispatchQueue(label: "canvas.work", qos: .utility),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
    func deliver(_ update: RoundUpdate)          // relays agentReply when the device matches and a peer is connected
    var pendingUploadCount: Int { get }          // for the status UI and tests
}
@MainActor final class CanvasHub {
    init(daemon: DaemonAPI, status: CanvasStatus)
    func makeSession(deviceName: String) -> CanvasSession     // registered weakly
    func start()                                              // consumes daemon.roundUpdates() and fans out
    func stop()
}
```

**Behaviour (spec sections 3 and 5.4):**
1. `canvasDidEncodeFrame` appends to the ring. No logging, no allocation beyond the copy.
2. `freeze`: parse `FreezeMessage`; look up the ring. Hit → reply `frozen {ok:true}` **immediately**, hold the frame as the connection's freeze capture, then on `workQueue` encode the PNG and `postCapture`; remember the returned capture id. Miss or unparseable → `frozen {ok:false}`. A second `freeze` before an `annotation` replaces the held capture and logs `discarding previous freeze capture`.
3. `annotation`: parse; if no held capture, log and drop. Otherwise take the held capture (clearing it) and enqueue a job on `workQueue`: composite (`Compositor`), ensure a capture id (re-post the capture if the freeze-time post failed), `postAnnotation` with the device id and name. Jobs run strictly in order. A failed upload is retried with `BackoffPolicy` until it succeeds; later jobs wait behind it. `.captureNotFound` re-posts the capture once, then retries. An undecodable sketch is logged and dropped (no retry).
4. `canvasPeerDidHello`: remember the peer and outbound; fetch `rounds(deviceID:limit: 20)` and send `RoundsMessage.encoded()` via `sendCanvasJSONData`. A failed fetch sends an empty snapshot.
5. `deliver`: when `update.deviceID` equals the peer's install id and an outbound exists, send `AgentReplyMessage` (message truncated to 2048 bytes, `t` = now in ms). Otherwise do nothing; the next `hello` snapshot covers it.
6. `canvasLinkDidDrop`: forget the outbound and the held freeze capture; keep queued uploads; keep the ring.
7. `canvasPingFields` returns `status.pingFields`.
8. All mutable state sits behind one lock. No delegate callback blocks: nothing on the sender queue does PNG work, compositing, or I/O.

**Required tests** (fakes: `FakeOutbound` recording sent objects and data; `FakeDaemon` with scripted results and recorded calls; small BGRA `CVPixelBuffer`s from `TestImages`; immediate `sleep`; wait with expectations or a bounded poll, never fixed sleeps): freeze hit → `frozen ok:true` and one capture post with the frame's dimensions; freeze 100 ms off → `ok:false` and no post; freeze garbage → `ok:false`; annotation after freeze → one `postAnnotation` whose `sourceCaptureId` is the capture id, with device id and name, zoom rect, note, and a composite that decodes to the expected size; annotation with no prior freeze → nothing posted; second freeze replaces the first (the upload's composite shows the second frame's colour); capture post failed at freeze → annotation path posts the capture first; daemon failing twice then succeeding → three attempts, order preserved across two queued annotations; `.captureNotFound` → capture re-posted then annotation succeeds; undecodable sketch → dropped, later jobs still run; hello → rounds fetched for the install id and the snapshot data parses to the same rounds; hello with a failing daemon → empty snapshot; `deliver` for this device → one `agentReply` with a truncated message; for another device → nothing; after link drop → nothing; after link drop a held freeze is gone (annotation dropped) but a queued upload still completes; ping fields reflect `CanvasStatus` (no `project` key when nil). `CanvasHubTests`: updates from the daemon stream reach the matching session only; a deallocated session is pruned; `stop` ends consumption.

- [ ] **Step 1:** Update `project.yml`, `./generate.sh`. Write `CanvasFakes.swift` and the freeze tests. RED. Implement the freeze path. GREEN. Commit.
- [ ] **Step 2:** Annotation, ordering, and retry tests. RED → GREEN. Commit.
- [ ] **Step 3:** Hello snapshot, deliver, link-drop, ping tests. RED → GREEN. Commit.
- [ ] **Step 4:** `CanvasHubTests`. RED → GREEN. Commit `feat(canvas): add CanvasSession and CanvasHub engine join`.
- [ ] **Step 5:** Run the OpenDisplay regression gate (project.yml changed).

---

### Task 10: Mac menu-bar app — target, ported shell, and engine integration

**Files:**
- Create under `DesignCanvas/Mac/App/`: `DesignCanvasMacApp.swift`, `AppModel.swift`, `MenuBarView.swift`, `SenderEngine.swift`, `OpenDisplaySenderEngine.swift`, `DaemonSupervisor.swift`, `ClaudeLauncher.swift`, `McpConfigManager.swift`, `SessionStateClassifier.swift`, `DisplayStateCopy.swift`, `ProcessResetService.swift`, `ProjectRecents.swift`, `ScreenRecordingPermission.swift`
- Create: `DesignCanvas/Mac/DesignCanvasMac.entitlements`; tests under `DesignCanvas/Tests/App/`
- Modify: `project.yml` (target `DesignCanvasMac`, scheme `DesignCanvasMac`; `DesignCanvasTests` gains the App sources except the three app-only files)
- Source to port: `/Users/zhao/Documents/Project_current/ai.cst.2/apps/desktop/DesignCanvasDesktop/` and `DesignCanvasDesktopTests/`. **Do not port:** `CaptureHUD`, `CaptureUploader`, `FrontmostAppTracker`, `GlobalHotkey`, `WindowCapturer`, `WindowSelection`, `HealthClient` (replaced by `DaemonClient`), or their tests.

**Interfaces:**
- Consumes: `SenderController`, `SenderControllerConfig`, `DeviceSession` (Task 4); `CanvasHub`, `CanvasStatus` (Task 9); `DaemonClient`, `DaemonHealth`, `HealthProbeResult`, `ChannelState(probe:)` (Task 8).
- Produces:

```swift
struct EngineDevice: Equatable, Identifiable { let id: String; let name: String; let status: String; let onUSB: Bool }
@MainActor protocol SenderEngine: AnyObject {            // fakeable in tests (spec section 1)
    var devices: [EngineDevice] { get }
    var onDevicesChanged: (() -> Void)? { get set }
    func start(); func stop()
    func setProjectName(_ name: String?)
    func setChannelState(_ state: ChannelState)
}
@MainActor final class OpenDisplaySenderEngine: SenderEngine   // app-only: wraps SenderController + CanvasHub
enum DaemonEnvironment { static func make(base: [String: String], port: Int) -> [String: String] }  // sets SERVER_PORT, removes SERVER_HOST
```

**`project.yml` target `DesignCanvasMac`:** `type: application`, macOS 14.0. Sources: `Shared`, `DesignCanvas/Shared`, `DesignCanvas/Mac`, and these files from `Mac/`: `MacSender.swift`, `SenderController.swift`, `SenderCanvasHooks.swift`, `ControlFramePolicy.swift`, `Usbmux.swift`, `Log.swift`, `LogPolicies.swift`, `DisplayArrangement.swift`, `VirtualDisplay.swift`, `TestPatternWindow.swift`, `CGVirtualDisplayPrivate.h` (plus `SenderDiscoveryConfig.swift` if Task 4 created it). **Never** `Mac/InputInjector.swift`, `Mac/OpenSidecarMacApp.swift`, `Mac/CheckForUpdatesView.swift`. No Sparkle dependency. `info.path: DesignCanvas/Mac/Info.plist` with `NSPrincipalClass: NSApplication`, `LSUIElement: true`, `CFBundleDisplayName: $(BUNDLE_DISPLAY_NAME)`, version keys as the other targets, `NSLocalNetworkUsageDescription: Design Canvas connects to your iPad over the local network in WiFi mode.`, `NSBonjourServices: ["_designcanvas._tcp"]`, `NSAppleEventsUsageDescription: Design Canvas launches Claude Code by sending a command to Terminal.`. Settings: bundle id `com.designcanvas.mac`, product and display name `Design Canvas`, bridging header `Mac/OpenSidecarMac-Bridging-Header.h`, hardened runtime, `CODE_SIGN_ENTITLEMENTS: DesignCanvas/Mac/DesignCanvasMac.entitlements` (same keys as `Mac/OpenSidecarMac.entitlements` plus `com.apple.security.automation.apple-events`), and a `Debug` config with `com.designcanvas.mac.debug` / `Design Canvas Dev`. Scheme `DesignCanvasMac` builds the app and runs `DesignCanvasTests`.

**Requirements:**
1. `OpenDisplaySenderEngine` builds `SenderController(config:)` with `bonjourType: "_designcanvas._tcp"`, `devicePort: 9100`, `inputSinkFactory: nil`, and a `canvasDelegateFactory` that returns `hub.makeSession(deviceName: session.name)`. It maps `controller.sessions` to `[EngineDevice]` and forwards project and channel state into `CanvasStatus`.
2. `AppModel` keeps ai.cst.2's behaviour (daemon supervision with the crash-loop guard 1.0 s / 2.0 s / 3, 2 s health poll, project picker and recents, `.mcp.json` ensure/update, Start session, Disconnect, Reset, 60 s launch timeout, session classifier) with these changes: health comes from `DaemonAPI.probe()`; all capture code is removed; it owns a `SenderEngine` (injected; default `OpenDisplaySenderEngine`), starts it at launch, and after every poll calls `engine.setChannelState(ChannelState(probe:))` and, on project change, `engine.setProjectName(selectedProject?.lastPathComponent)`. The port constant stays 47100. `DaemonSupervisor`'s runner uses `DaemonEnvironment.make` so the daemon can never be LAN-bound.
3. `MenuBarView` sections, in order: daemon and session status line, reset (same visibility rules), devices (name, status, USB/WiFi, from `engine.devices`; empty state "No iPad connected — open Design Canvas on the iPad"), Screen Recording permission row with a Grant button, server build, project, session controls, Quit. No capture section, no iPad URL.
4. The app never imports or calls Accessibility APIs. `grep -rn "AXIsProcessTrusted\|InputInjector" DesignCanvas/` prints nothing.
5. Reset never kills Claude Code (ported kill-gate rules unchanged).

**Required tests.** Port these ai.cst.2 suites, replacing `@testable import` with direct compilation: `AppModelTests` (minus capture cases; `probe` injection now returns the new `HealthProbeResult`), `DaemonSupervisorTests`, `ClaudeLauncherTests`, `McpConfigManagerTests`, `ProcessResetServiceTests`, `ProjectRecentsTests`, `SessionStateClassifierTests`. Add: `DaemonEnvironment.make` sets the port and strips an inherited `SERVER_HOST`; with a `FakeSenderEngine`, `AppModel` starts the engine once, pushes `.attached`/`.detached`/`.none` after polls with the matching probe results, pushes the project folder name on select and `nil` when cleared; device list changes republish.

- [ ] **Step 1:** Add the test sources entry to `project.yml` (App path with `excludes: [DesignCanvasMacApp.swift, OpenDisplaySenderEngine.swift, MenuBarView.swift]`), `./generate.sh`. Port the pure suites (classifier, MCP config, recents, launcher, reset, supervisor). RED. Port their sources. GREEN. Commit `feat(canvas-mac): port session shell logic from ai.cst.2`.
- [ ] **Step 2:** Write the new `DaemonEnvironment` and `AppModel` engine tests plus the ported `AppModelTests`. RED. Port and adapt `AppModel`, add `SenderEngine.swift`. GREEN. Commit.
- [ ] **Step 3:** Add the app target, entitlements, `DesignCanvasMacApp.swift`, `MenuBarView.swift`, `OpenDisplaySenderEngine.swift`. `./generate.sh`. Build `DesignCanvasMac`. Expected `BUILD SUCCEEDED`, no warnings from Design Canvas files. Commit `feat(canvas-mac): add the Design Canvas menu-bar app target`.
- [ ] **Step 4:** Run requirement 4's grep, the Design Canvas tests, and the OpenDisplay regression gate.

---

### Task 11: Receiver core — configurable discovery, canvas callbacks, freeze, and `ReceiverModel` extraction

**Files:**
- Create: `Shared/CanvasReceiverState.swift`, `iOS/ReceiverModel.swift`, `DesignCanvas/Tests/CanvasReceiverStateTests.swift`
- Modify: `Shared/StreamReceiver.swift`, `iOS/OpenSidecarPhoneApp.swift`, `project.yml` (`DesignCanvasTests` sources add `Shared/CanvasReceiverState.swift`)

**Interfaces:**
- Produces:

```swift
// Shared/CanvasReceiverState.swift — Foundation only, macOS 12 safe, pure
struct CanvasReceiverState: Equatable {
    private(set) var macSupportsCanvas = false
    private(set) var channel: String?            // "attached" | "detached" | "none"
    private(set) var project: String?
    private(set) var frozen = false
    var suppressesInput = false
    enum Routed: Equatable { case none, canvasMessage(type: String) }
    mutating func connectionReset()                               // new connection adopted: canvas false, channel/project nil, frozen false
    mutating func handleWelcome(_ obj: [String: Any])             // canvas == true only for a JSON true
    mutating func handlePing(_ obj: [String: Any])                // absent project clears it; absent channel leaves it
    mutating func route(type: String) -> Routed                   // frozen/agentReply/rounds -> .canvasMessage only when macSupportsCanvas
    mutating func setFrozen(_ value: Bool) -> Bool                // returns true when a keyframe must be requested (true -> false edge)
    var shouldDropFrames: Bool { get }                            // frozen
    var allowsInputSend: Bool { get }                             // !suppressesInput
}
// StreamReceiver additions
init(displayLayer:deviceKind:fallbackServiceName:maxEncodeWide:maxEncodeHigh:serviceType: String = "_opensidecar._tcp")
@Published private(set) var canvas = CanvasReceiverState()
var suppressesInput: Bool { get set }
var onCanvasMessage: ((_ type: String, _ object: [String: Any]) -> Void)?     // main queue
var onWelcome: ((_ canvas: Bool) -> Void)?                                     // main queue
func setFrozen(_ frozen: Bool)
func currentCaptureMs() -> Int64?                  // capture ms of the last frame actually enqueued for display
func sendCanvas(_ message: [String: Any], completion: ((Bool) -> Void)? = nil) // true when the socket write completed without error
// iOS/ReceiverModel.swift
ReceiverModel.init(port: UInt16 = 9000, serviceType: String = "_opensidecar._tcp", defaultsNameKey unchanged)
```

**Requirements:**
1. `advertisedService` uses `serviceType`. OpenDisplay callers pass nothing and behave as before.
2. `StreamReceiver` owns one `CanvasReceiverState`, mutated on its own queue and published to main: `connectionReset()` in `adopt`, `handleWelcome` in the `welcome` case (then `onWelcome`), `handlePing` in the `ping` case, `route` in `default` (then `onCanvasMessage`).
3. `enqueueFrame` drops frames while `canvas.shouldDropFrames`, next to the existing `renderingPaused` check, and records `lastEnqueuedCaptureMs` only for frames that pass. On unfreeze it requests a keyframe the same way `setRenderingPaused(false)` does. The display layer keeps showing the last frame while frozen.
4. `sendTouch`, `sendScroll`, `sendPencil`, `sendProximity` return early when `!canvas.allowsInputSend`.
5. `ReceiverModel` (and the `deviceKind` constant it needs) moves verbatim to `iOS/ReceiverModel.swift` and gains the two init parameters; OpenDisplay's app keeps calling `ReceiverModel()`.
6. Everything added to `Shared/` compiles at macOS 12 (the receiver build proves it).

**Required tests** (`CanvasReceiverStateTests`): welcome with `canvas: true`, `false`, absent, and the string `"true"` (only the first enables); ping sets channel and project; ping without `project` clears it; ping without `channel` keeps it; `route` returns `.canvasMessage` for the three types only after a canvas welcome and `.none` for `cursor` or before welcome; `connectionReset` clears everything including `frozen`; `setFrozen` returns true only on the true→false edge; `allowsInputSend` follows `suppressesInput`.
Also attempt one loopback integration test, `StreamReceiverCanvasLoopbackTests`, only if `Shared/StreamReceiver.swift` compiles into the hostless bundle without pulling in more than `Shared/` and `Mac/Log.swift`: start a receiver on an ephemeral port, connect an `NWConnection` as a fake Mac, read `hello`, send a canvas `welcome`, assert `canvas.macSupportsCanvas`, send `frozen` and assert `onCanvasMessage`, call `sendCanvas` and assert the framed JSON arrives, set `suppressesInput` and assert `sendTouch` emits nothing. If the listener is not ready within 2 s, `throw XCTSkip`. If compiling it needs more than those sources, skip this test and say so in the report.

- [ ] **Step 1:** Write `CanvasReceiverStateTests`, register the source, `./generate.sh`. RED. Implement. GREEN. Commit `feat(shared): add pure canvas receiver state`.
- [ ] **Step 2:** Wire `StreamReceiver` (requirements 1–4). Run the full OpenDisplay regression gate. Commit `feat(shared): canvas callbacks, freeze, and configurable service type in StreamReceiver`.
- [ ] **Step 3:** Extract `ReceiverModel`. Regression gate. Commit `refactor(ios): extract ReceiverModel with injectable port and service type`.
- [ ] **Step 4:** Attempt the loopback test per the rule above. Commit if kept.

---

### Task 12: iPad app — target, view-only zoom, Draw Mode, agent replies, connection status

**Files:**
- Create under `DesignCanvas/iOS/Logic/` (Foundation + Combine only, compiled into the hostless tests): `ZoomModel.swift`, `CanvasModel.swift`
- Create under `DesignCanvas/iOS/`: `DesignCanvasApp.swift`, `CanvasScreen.swift`, `CanvasVideoView.swift`, `SketchCanvas.swift`, `DrawModeOverlay.swift`, `AgentRepliesView.swift`, `ConnectionStatusView.swift`, `ReceiverAdapter.swift`, `DesignCanvasiOS.entitlements`
- Create: `DesignCanvas/Tests/ZoomModelTests.swift`, `DesignCanvas/Tests/CanvasModelTests.swift`
- Modify: `project.yml` (target and scheme `DesignCanvasiOS`; `DesignCanvasTests` sources add `DesignCanvas/iOS/Logic`)
- Reference for PencilKit wiring: `/Users/zhao/Documents/Project_current/ai.cst.2/apps/ipad/DesignCanvas/PencilCanvasView.swift` (reuse its canvas setup and transparent-PNG export; its composite path and scroll-view zoom are not used).

**Interfaces:**
- Consumes: `DrawModeStateMachine`, all message types (Task 1); `StreamReceiver` canvas API and `ReceiverModel(port:serviceType:)` (Task 11).
- Produces:

```swift
struct ZoomModel: Equatable {                       // view-only zoom of the mirrored video (C2)
    static let minScale = 1.0, maxScale = 6.0
    private(set) var scale = 1.0
    private(set) var offset = CGSize.zero           // points, relative to the fitted video's centre
    var isLocked = false                            // true in Draw Mode: gestures are ignored
    mutating func pinch(by factor: Double, anchor: CGPoint, viewSize: CGSize, videoSize: CGSize)
    mutating func pan(by delta: CGSize, viewSize: CGSize, videoSize: CGSize)   // clamped so the video always covers what it can
    mutating func reset()
    static func fittedRect(videoSize: CGSize, in viewSize: CGSize) -> CGRect   // aspect-fit
    func visibleRect(viewSize: CGSize, videoSize: CGSize) -> NormalizedRect    // part of the video on screen; .full at scale 1
}
protocol CanvasReceiving: AnyObject {               // StreamReceiver behind ReceiverAdapter; faked in tests
    var isConnected: Bool { get }
    var supportsCanvas: Bool { get }
    func currentCaptureMs() -> Int64?
    func setFrozen(_ frozen: Bool)
    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void)
}
@MainActor final class CanvasModel: ObservableObject {
    init(receiver: CanvasReceiving, nowMs: @escaping () -> Double, uptime: @escaping () -> TimeInterval)
    @Published private(set) var drawState: DrawModeStateMachine.State
    @Published private(set) var rounds: [CanvasRound]                 // newest first, at most 20
    @Published private(set) var notice: DrawModeStateMachine.Notice?
    @Published private(set) var channel: ChannelState                 // .none until a ping says otherwise
    @Published private(set) var project: String?
    @Published var note: String
    var canEnterDrawMode: Bool { get }      // live && connected && supportsCanvas
    var canSend: Bool { get }
    var shouldClearStrokes: Bool { get }    // edge flag the view consumes via strokesCleared()
    func enterDrawMode(zoomRect: NormalizedRect, viewport: CanvasViewport)
    func strokesChanged(count: Int)
    func done(sketchPNG: Data)
    func cancel(); func discard(); func rotated(); func strokesCleared(); func dismissNotice()
    func tick()
    func connectionChanged(connected: Bool)
    func welcomeReceived(canvas: Bool)
    func pingReceived(channel: String?, project: String?)
    func canvasMessage(type: String, object: [String: Any])
}
```

**Behaviour:**
1. `CanvasModel` executes state-machine effects: `pauseSync` → `receiver.setFrozen(true)`; `resumeSync` → `setFrozen(false)`; `sendFreeze` → `FreezeMessage(captureMs: currentCaptureMs, zoomRect, t)`; `sendAnnotation` → the stored `AnnotationMessage`, and on completion `true` → `.sent`, `false` → `.linkLost`; `clearStrokes` → `shouldClearStrokes = true` and the stored sketch and note are dropped; `show` → `notice`.
2. `enterDrawMode` with no `currentCaptureMs()` shows `.noFrame` and stays live. The zoom rect and viewport given at entry are the ones sent with the annotation (zoom is locked while drawing).
3. `connectionChanged(false)` → `.linkLost`. `welcomeReceived(canvas: true)` → `.helloReceived` (this is the resend trigger). `canvasMessage`: `frozen` → `.frozen(ok:)`; `rounds` replaces the list; `agentReply` updates the matching round or inserts it at the front, keeping at most 20. Malformed messages are ignored.
4. On every canvas connection `ReceiverAdapter` sets `receiver.suppressesInput = true` before `start`, so no input message is ever sent (M3, spec section 1).
5. Views: `CanvasScreen` shows the mirror (`CanvasVideoView`: a `UIView` hosting `receiver.displayLayer`, aspect-fit, transformed by `ZoomModel`; pinch and two-finger or one-finger pan; double-tap resets) with a floating panel: `ConnectionStatusView` (two dots for iPad↔Mac and Mac↔Claude Code, plus the project name or `unselected`; tap opens a sheet with the receiver status text, channel state, port 9100, service type, last notice, and the diagnostics log), a Draw button (P3), and a Replies button. In Draw Mode `DrawModeOverlay` covers the mirror with `SketchCanvas` (`PKCanvasView`, transparent, `drawingPolicy = .anyInput`) and a tool panel: pen, eraser, undo (`undoManager`), five colours, an optional single-line note field (M4), Cancel (keeps strokes, M6), Discard, and Done (disabled unless `canSend`). Done exports `drawing.image(from: bounds, scale: screen scale)` as PNG and calls `done(sketchPNG:)`. Strokes kept after cancel, rotation, link loss, or a failed freeze reappear on the next entry. A size change while in Draw Mode calls `rotated()`. Notices render as a dismissible banner. `AgentRepliesView` lists rounds with a status badge (`queued`, `sent`, `applied`, `failed`, `needs input`), message, note, and a tappable PR link (M8). A 0.5 s timer calls `tick()` only while freezing.
6. When connected to a Mac that did not send `canvas: true`, Draw is disabled and the status sheet says the Mac app is not Design Canvas.

**`project.yml` target `DesignCanvasiOS`:** iOS 16.4, `TARGETED_DEVICE_FAMILY: "2"`. Sources: `Shared`, `DesignCanvas/Shared`, `DesignCanvas/iOS`, `iOS/Log.swift`, `iOS/ReceiverModel.swift`, `iOS/DiagnosticsLogView.swift`. Info: display name `Design Canvas`, `UILaunchScreen: {}`, `UIRequiresFullScreen: true`, all four orientations, `NSLocalNetworkUsageDescription: Design Canvas advertises itself on the local network so your Mac can connect over WiFi.`, `NSBonjourServices: ["_designcanvas._tcp"]`. Bundle id `com.designcanvas.ipad`, Debug `com.designcanvas.ipad.debug`. The app starts `ReceiverModel(port: 9100, serviceType: "_designcanvas._tcp")`.

**Required tests.** `ZoomModelTests`: fitted rect for wider and taller video; scale clamps to 1…6; at scale 1 `visibleRect` is `.full` and pan is a no-op; pinch 2× at the centre gives the centred half rect; pinch at a corner keeps that corner fixed; pan clamps at each edge; locked model ignores pinch and pan; reset. `CanvasModelTests` with a `FakeReceiver`: enter → `setFrozen(true)` and a `freeze` carrying the receiver's capture ms and the entry zoom rect; no capture ms → notice, still live, nothing sent; `frozen ok:true` → drawing; `ok:false` → live, unfrozen, notice, strokes flag not set; timeout via `tick` after 2 s; done with strokes → `annotation` with the sketch bytes, entry zoom rect, viewport, note, then `setFrozen(false)`; completion true → live and `shouldClearStrokes`; completion false → retry, then `welcomeReceived(true)` resends the same payload; cancel keeps strokes flag false; discard sets it; `connectionChanged(false)` while drawing → live with the link-loss notice; `rounds` replaces the list; `agentReply` updates in place and inserts unknown ids at the front, capped at 20; ping updates channel and project; `canEnterDrawMode` false when disconnected or when canvas is unsupported; malformed messages ignored.

- [ ] **Step 1:** Register `DesignCanvas/iOS/Logic` in the test target, `./generate.sh`. Write `ZoomModelTests`. RED. Implement. GREEN. Commit `feat(canvas-ios): add view-only zoom model`.
- [ ] **Step 2:** Write `CanvasModelTests`. RED. Implement `CanvasModel`. GREEN. Commit `feat(canvas-ios): add canvas view-model driving Draw Mode`.
- [ ] **Step 3:** Add the target, entitlements, and the views. `./generate.sh`. Build `DesignCanvasiOS`. Expected `BUILD SUCCEEDED`, no warnings from Design Canvas files. Commit `feat(canvas-ios): add the Design Canvas iPad app`.
- [ ] **Step 4:** Verify `grep -rn "sendTouch\|sendScroll\|sendPencil\|sendProximity" DesignCanvas/` prints nothing. Run the Design Canvas tests and the OpenDisplay regression gate.

---

### Task 13: End-to-end round script, protocol addendum, docs, and CI

**Files:**
- Create: `DesignCanvas/server/scripts/e2e-round.mjs`, `DesignCanvas/README.md`, `DesignCanvas/spec/device-checklist.md`, `DesignCanvas/spec/reply-compliance-eval.md`
- Modify: `DesignCanvas/server/package.json` (script `test:e2e`), `PROTOCOL.md`, `.github/workflows/tests.yml`

**Requirements:**
1. `e2e-round.mjs` (run by `pnpm --dir DesignCanvas/server test:e2e`; Node only, no devices) starts the built daemon on a free port with a temp store and asserts three scenarios, printing one `ok`/`FAIL` line each and exiting non-zero on any failure: **round** — open the rounds stream as the engine would, attach a real `--channel` process through an MCP stdio client, post a capture and an annotation for device `ipad-A`, observe `queued` then `sent` on the stream and one channel notification, call `design_canvas_reply` with `applied` and a PR URL, observe `applied` on the stream, and check `/v1/rounds?device=ipad-A`; **backlog** — post two annotations with no channel attached, attach the channel, assert both notifications arrive in creation order at least 1 s apart; **reconnect snapshot** — with a second device `ipad-B`, assert `/v1/rounds?device=ipad-B` excludes `ipad-A`'s rounds and that a reply recorded while no stream was open is present in the snapshot.
2. `PROTOCOL.md` gains a section "Design Canvas extension (additive, no pv bump)": the `welcome.canvas` gate; the five messages with direction, fields, and types exactly as implemented; `ping.channel` and `ping.project`; the 16 MiB canvas receiver-to-sender cap with 256 KiB chunked reads and the rule that an oversize frame closes the link; the sender-side refusal of JSON at or above 32768 bytes; the rule that a canvas session carries no input messages; port 9100 and `_designcanvas._tcp`. State that OpenDisplay peers ignore all of it.
3. `DesignCanvas/README.md`: what Design Canvas is; the folder map; prerequisites (Xcode, XcodeGen, Node >= 20.10, pnpm, Claude Code signed in with claude.ai); build and run steps for the daemon, the Mac app, and the iPad app; first-session walkthrough (pick project, set server build to `DesignCanvas/server/dist/index.js`, Start session, keep the terminal on the mirrored display so permission prompts are visible — owner decision D20); **security note**: WiFi uses OpenDisplay's trust-on-first-use, a LAN neighbour who spoofs a remembered Bonjour id can push a sketch into the session, use USB on shared networks, encrypted transport is tracked in `spec/TODOS.md`; known limits (no reply timeout — a round can stay `sent`; relaunching the Mac app orphans a running session; manually started Claude Code sessions are unsupported; unverified Claude Code prompt assumptions D22); the deferred list from ruling 9; license GPL-3.0.
4. `spec/device-checklist.md`: a manual checklist for USB and WiFi covering pairing, mirror, zoom, freeze exactness (draw on a moving test pattern and compare `screenshot.png`), zoomed crop, Done under 1 s to delivery, reply shown, link loss mid-upload with resend, rotation in Draw Mode, reconnect snapshot, and both connection dots. `spec/reply-compliance-eval.md`: the 10-round protocol with a 9/10 threshold and a results table to fill in.
5. `tests.yml`: after the existing steps add — Design Canvas Swift tests (`-scheme DesignCanvasMac`, which also compile-checks the Mac app), the unsigned `DesignCanvasiOS` build, and a Node job or steps (`actions/setup-node` with Node 22, `corepack enable` or `pnpm/action-setup`, then `install`, `typecheck`, `test`, `test:channel`, `test:e2e` in `DesignCanvas/server`). Keep the existing comments and the no-secrets property.

- [ ] **Step 1:** Write `e2e-round.mjs` scenario by scenario; each scenario is first run to see it fail for a real reason where one exists (for example, run **backlog** with the spacing assertion before confirming the implementation satisfies it), then made to pass. If a scenario exposes a daemon or channel bug, fix it test-first in the owning module and say so in the report. Commit `test(canvas-server): add end-to-end round script`.
- [ ] **Step 2:** Write the `PROTOCOL.md` section by reading the implemented code, not this plan. Commit `docs(protocol): document the Design Canvas extension`.
- [ ] **Step 3:** Write the README and the two spec checklists. Commit `docs(canvas): add README, device checklist, and reply-compliance eval`.
- [ ] **Step 4:** Extend `tests.yml`. Validate the YAML parses (`ruby -ryaml -e 'YAML.load_file(".github/workflows/tests.yml")'`). Commit `ci: build and test Design Canvas`.
- [ ] **Step 5:** Run every verification command in this plan once and paste the summary lines into the report.
