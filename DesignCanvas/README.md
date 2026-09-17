# Design Canvas

Design Canvas turns a live OpenDisplay mirror into a sketch-and-reply loop
with Claude Code: draw on the iPad while it mirrors your Mac, and the
sketch is pushed straight into a running Claude Code session as an
annotated screenshot; the agent's outcome (applied, failed, or a question)
shows back up on the iPad.

It is a separate pair of apps — a Mac menu-bar app and an iPad app — built
on top of OpenDisplay's mirroring code, plus a small local Node daemon and
an MCP channel process that Claude Code spawns. No input is ever forwarded
from the iPad: it is a display and a sketchpad, never a remote control.

**Status:** the Node half (daemon, channel, this whole round lifecycle) is
proven end to end without hardware — see
[`server/scripts/e2e-round.mjs`](server/scripts/e2e-round.mjs) and
`pnpm --dir DesignCanvas/server test:e2e` below. **Nothing in this feature
has run against real devices yet.** [`spec/device-checklist.md`](spec/device-checklist.md)
is the manual pass that still needs to happen on real hardware before this
is considered proven end to end.

## What's in here

```
DesignCanvas/
  README.md                 This file.
  spec/                      PRD, technical spec, TODOs, the implementation
                              plan, the device checklist, the reply-compliance
                              eval — see below.
  Shared/                    Foundation-only wire types and pure logic,
                              compiled into the Mac app, the iPad app, and
                              the hostless test bundle.
    CanvasMessages.swift        Wire structs (FreezeMessage, AnnotationMessage,
                                 AgentReplyMessage, RoundsMessage, ...) and the
                                 CanvasWire constants — see PROTOCOL.md section 11.
    DrawModeStateMachine.swift  The iPad's Draw Mode state machine, as a pure
                                 struct.
  Mac/
    Engine/                    The in-process engine: FrameRing, Compositor,
                                DaemonClient, CanvasSession, CanvasHub,
                                UploadPipeline, SSEParser. Hostless-testable;
                                no live socket in any of it.
    App/                       The menu-bar app shell: AppModel, MenuBarView,
                                DaemonSupervisor, ClaudeLauncher,
                                McpConfigManager, SessionStateClassifier,
                                ProcessResetService, ProjectRecents,
                                ScreenRecordingPermission, SenderEngine /
                                OpenDisplaySenderEngine.
    DesignCanvasMac.entitlements
  iOS/
    DesignCanvasApp.swift, CanvasScreen.swift, CanvasVideoView.swift,
    DrawModeOverlay.swift, SketchCanvas.swift, AgentRepliesView.swift,
    ConnectionStatusView.swift, ReceiverAdapter.swift
    Logic/                     CanvasModel.swift, ZoomModel.swift — the pure,
                                testable logic behind the views above.
    DesignCanvasiOS.entitlements
  Tests/                       The hostless XCTest bundle, `DesignCanvasTests`.
  server/                      The Node package: daemon (--http) + channel
                                (--channel). See server/README.md for its
                                own module map and hard rules.
```

Design Canvas also adds a handful of small, inert-by-default hooks to
OpenDisplay's own code, so those apps behave exactly as before unless a
Design Canvas object is actually injected: `Mac/ControlFramePolicy.swift`,
`Mac/SenderCanvasHooks.swift`, `Mac/SenderController.swift` (all new), plus
small additions to `Mac/MacSender.swift`, `Shared/Protocol.swift`,
`Shared/StreamReceiver.swift`, and a new `Shared/CanvasReceiverState.swift`
and `iOS/ReceiverModel.swift`. `PROTOCOL.md` section 11 is the normative
description of everything that crosses the wire.

## Prerequisites

- Xcode (current stable) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node >= 20.10 and [pnpm](https://pnpm.io)
- An iPad on iOS/iPadOS 16.4+, on the same network or a USB cable
- Claude Code, signed in with a claude.ai account (Console API keys cannot
  use Channels — see "Known limits" below), with the
  `--dangerously-load-development-channels` flag available

## Build and run

The Xcode project is generated, not checked in. From the repo root:

```sh
./generate.sh
```

Regenerate this after any `project.yml` change; never edit
`OpenSidecar.xcodeproj` directly.

### The daemon (Node)

```sh
pnpm --dir DesignCanvas/server install
pnpm --dir DesignCanvas/server build
pnpm --dir DesignCanvas/server start          # designtool --http, on 127.0.0.1:47100
```

The Mac app supervises this process for you in normal use — the manual
`start` above is for developing the daemon on its own. Point the Mac app's
"Set server build…" picker at `DesignCanvas/server/dist/index.js` (see
"First session" below).

### The Mac app

```sh
xcodebuild build \
  -project OpenSidecar.xcodeproj \
  -scheme DesignCanvasMac \
  -destination 'platform=macOS'
```

Or open `OpenSidecar.xcodeproj` in Xcode and run the `DesignCanvasMac`
scheme. It needs Screen Recording (granted from the app's menu — it is the
*only* TCC permission it asks for; it never requests Accessibility,
because it never injects input).

### The iPad app

```sh
xcodebuild build \
  -project OpenSidecar.xcodeproj \
  -scheme DesignCanvasiOS \
  -destination 'generic/platform=iOS'
```

Or open the project in Xcode, select the `DesignCanvasiOS` scheme and a
real device or simulator, and run.

## First session

1. Launch the Mac app. Grant Screen Recording if it isn't already granted
   (this needs one relaunch to take effect).
2. Open the Design Canvas app on the iPad and leave it open. The iPad is
   the listener: it has no list of Macs and nothing to pick. Over **USB**,
   plugging the cable in connects on its own. Over **WiFi**, the iPad
   appears under **iPads** in the Mac app's menu — click **Connect** next
   to it. That first click is also what makes the Mac auto-reconnect that
   iPad on later launches; **Disconnect** stops both the session and the
   auto-reconnect.
3. In the Mac app, click **Open Project…** and choose the repo you want
   Claude Code to work in (or pick it from **Recent projects**).
4. Click **Set server build…** and point it at
   `DesignCanvas/server/dist/index.js` (built above). The app remembers
   this path.
5. Click **Start session**. This launches a Terminal window running
   `claude --dangerously-load-development-channels server:design-canvas`
   in your project directory, and writes (or updates) that project's
   `.mcp.json` with the `design-canvas` channel entry.
6. **Keep that Terminal window on the mirrored display** (owner decision
   D20). Claude Code's own permission prompts (tool-use confirmations,
   etc.) still appear there, and nothing is relayed to the iPad while one
   is waiting — the mitigation for now is that you can see it because it's
   on the screen you're mirroring. One consequence: since the terminal is
   on the mirrored screen, it can end up inside a sketch's captured frame
   or composite. Zoom into just the region you're drawing on before you
   draw to keep it out of the crop.
7. On the iPad: pinch to zoom into the area you want to annotate, enter
   Draw Mode, sketch, optionally add a note, and tap Done. The composite
   (your sketch flattened over the clean frame) is pushed to Claude Code as
   soon as it's ready; you'll see the round go from queued to sent, and
   Claude Code's reply (applied / failed / needs input, plus an optional PR
   link) shows up on the iPad once it calls `design_canvas_reply`.

## Security note

WiFi connections use OpenDisplay's existing trust-on-first-use model: a
brand-new device needs one click (**Connect**, in the Mac app's menu) and
is remembered from then on, after which its Bonjour `id` auto-reconnects
with no prompt. There is no pairing code and no verification of that id, so
**a LAN neighbour who spoofs a remembered device's Bonjour id can get
dialed and push a sketch into your Claude Code session** — the same way any OpenDisplay peer could
push input on a plain mirroring session, except here what lands is a
sketch that becomes context for an agent that can edit your files.

**Prefer USB on a shared or untrusted network.** Encrypted WiFi transport
with a real pairing step is tracked as future work in
[`spec/TODOS.md`](spec/TODOS.md) (OpenDisplay upstream issue #16); it isn't
built yet.

The daemon listens on `127.0.0.1:47100` only, which keeps other machines
out — but binding to loopback does **not** keep a *browser* out. A page on
any site can be served a hostname that resolves to 127.0.0.1 (DNS
rebinding) and then talk to the daemon as same-origin: enough to post a
capture and an annotation carrying someone else's note and image, which is
prompt injection straight into your Claude Code session, or to read back
`GET /v1/annotations`. So the daemon refuses any request whose `Host` is not
`127.0.0.1`, `localhost` or `[::1]` on its own port, and any request that
carries an `Origin` header at all — every legitimate client here is a
program, and none of them sends one.

**Residual risk:** that defence is about browsers, not about the machine.
Any local user or process on this Mac can still post captures,
annotations and replies to the daemon — there is no authentication on the
loopback API — and an annotation is context for an agent that can edit your
files. Treat the daemon as trusting everything already running on your Mac.

## Known limits

- **No reply timeout.** A round that Claude Code never replies to (the
  channel wasn't loaded, the model never called the tool, or it's stuck
  behind a permission prompt) stays `sent` forever — there is no timeout or
  synthetic failure status. This was an explicit owner decision (D21); the
  reply-compliance eval below is the only measurement of how often it
  happens in practice.
- **Relaunching the Mac app orphans a running session.** Session ownership
  is tracked in-process (see technical_doc.md section 6); if the Mac app
  quits and relaunches while Claude Code is still running, it can no
  longer tell that it owns that session. Use **Reset** rather than
  force-quitting if you need to recover.
- **Manually started Claude Code sessions are unsupported.** The app only
  recognizes a channel it launched itself; running
  `claude --dangerously-load-development-channels server:design-canvas`
  by hand outside the app's own Terminal launch is not a supported path.
- **Two assumptions about Claude Code's own prompting behavior are
  unverified**, kept as-is by owner decision D22: that reading a file under
  the store path (`~/.claude/channels/design-canvas/`) never triggers a
  permission prompt, and that the committed `.mcp.json` entry doesn't
  trigger the project-level MCP trust prompt for you or for a collaborator
  who inherits the file. If either turns out to prompt in practice, the
  fix is an app-managed allow rule or a user-scoped MCP config — not yet
  built.

## Deferred (not built)

Recorded here rather than left silently unbuilt, per the implementation
plan's ruling 9:

- Custom app icons (design still open, G18).
- Sparkle update wiring and an appcast feed (no feed exists yet).
- A release/signing/notarization pipeline for the Mac app.
- Metal rendering on the iPad (the current layer-based path already makes
  freeze/Draw Mode fast enough; revisit only if that changes).
- Redo and clear-all in Draw Mode (open design question, G6).
- Automated device-level end-to-end testing — it needs real hardware.
  [`spec/device-checklist.md`](spec/device-checklist.md) is the manual
  checklist that stands in for it.

See [`spec/TODOS.md`](spec/TODOS.md) for the fuller backlog (encrypted WiFi
transport, an MCP tool that returns the composite as an image block,
batched-turn measurement, a pending-round TTL) and
[`spec/technical_doc.md`](spec/technical_doc.md) section 10 for every
decision and open question behind this feature.

## Verifying a change

From the repo root:

```sh
# Regenerate after any project.yml change
./generate.sh

# OpenDisplay regression gate — must stay green for any change touching
# Mac/, Shared/, iOS/, or project.yml
xcodebuild test  -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO
xcodebuild build -project OpenSidecar.xcodeproj -scheme OpenSidecarMacReceiver -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO
xcodebuild build -project OpenSidecar.xcodeproj -scheme OpenSidecariOS -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO

# Design Canvas Swift tests (hostless bundle)
xcodebuild test -project OpenSidecar.xcodeproj -scheme DesignCanvas -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO

# Design Canvas apps build
xcodebuild build -project OpenSidecar.xcodeproj -scheme DesignCanvasMac -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO
xcodebuild build -project OpenSidecar.xcodeproj -scheme DesignCanvasiOS -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO

# Node
pnpm --dir DesignCanvas/server install
pnpm --dir DesignCanvas/server typecheck
pnpm --dir DesignCanvas/server test
pnpm --dir DesignCanvas/server test:channel   # two-process channel topology, real MCP stdio
pnpm --dir DesignCanvas/server test:e2e       # full round lifecycle, no devices
```

A harmless `IDETesting: Result bundle saving failed ... chmod: Operation
not permitted` line after `TEST SUCCEEDED` is sandbox noise in some
environments, not a failure.

## License

GPL-3.0, same as OpenDisplay. Design Canvas is a derivative work built on
OpenDisplay's sender and receiver code; see `LICENSE` at the repo root.
