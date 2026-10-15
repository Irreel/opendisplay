# Design Canvas

Design Canvas turns a live OpenDisplay mirror into a sketch-and-reply loop
with Claude Code: draw on the iPad while it mirrors your Mac, and the
sketch is pushed straight into a running Claude Code session as an
annotated screenshot; the agent's outcome (applied, failed, or a question)
shows back up on the iPad.

It is a separate pair of apps — a Mac menu-bar app and an iPad app — built
on top of OpenDisplay's mirroring code, plus a small local Node daemon and
a Claude Code mod, a plugin that runs inside the Claude Code session. No input is ever forwarded
from the iPad: it is a display and a sketchpad, never a remote control.

**Status:** the Node half (daemon, mod, the whole round lifecycle) has an
automated end-to-end test that needs no devices — see
[`server/scripts/e2e-round.mjs`](server/scripts/e2e-round.mjs) and
`pnpm --dir DesignCanvas/server test:e2e` below. Everything that needs a
real Mac and iPad is checked by hand with
[`spec/device-checklist.md`](spec/device-checklist.md).

**Claude Code mod (2026-10-05).** Sketches now reach Claude Code through a
mod instead of an MCP channel: no development flag, nothing written into
your project, a clear outcome for every sketch, and any session with the
mod loaded is usable (see [`spec/PRD-ClaudeMods.md`](spec/PRD-ClaudeMods.md)
and [`spec/technical_doc-ClaudeMods.md`](spec/technical_doc-ClaudeMods.md)).
The channel process still ships in `server/` for
the reply-compliance baseline; the app no longer uses it.

## What's in here

```
DesignCanvas/
  README.md                 This file.
  spec/                      PRD, technical spec, TODOs, the implementation
                              plan, the device checklist, the reply-compliance
                              eval — see below. The blank canvas surface has
                              its own pair, PRD-BlankCanvas.md and
                              technical_doc-BlankCanvas.md (2026-10-03).
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
                                ClaudeSettingsManager, SessionStateClassifier,
                                ProcessResetService, ProjectRecents,
                                ScreenRecordingPermission, SenderEngine /
                                OpenDisplaySenderEngine.
    DesignCanvasMac.entitlements
  iOS/
    DesignCanvasApp.swift, CanvasScreen.swift (the screen and its chrome),
    CanvasVideoView.swift, SketchCanvas.swift, ControlPanel.swift (the
    floating panel), ProjectPill.swift (the session pill and list),
    ReplyNotificationCard.swift, ConnectionStatusView.swift (connection
    details), CanvasColors.swift (the colour tokens), ReceiverAdapter.swift
    Logic/                     CanvasModel.swift, ZoomModel.swift,
                                PanelDock.swift, ReplyNotification.swift —
                                the pure, testable logic behind the views
                                above.
    DesignCanvasiOS.entitlements
  Tests/                       The hostless XCTest bundle, `DesignCanvasTests`.
  mod/                         The Claude Code mod: one plain-JavaScript hooks
                                module, bundled into the Mac app at build time
                                (tools/bundle-mod.sh). Its tests run with the
                                server's.
  server/                      The Node package: daemon (--http), which also
                                keeps the list of connected sessions, and the
                                older channel (--channel). See server/README.md
                                for its own module map and hard rules.
```

Design Canvas also adds a handful of small, inert-by-default hooks to
OpenDisplay's own code, so those apps behave exactly as before unless a
Design Canvas object is actually injected: `Mac/ControlFramePolicy.swift`,
`Mac/SenderCanvasHooks.swift`, `Mac/SenderController.swift`,
`Mac/CaptureMode.swift` (all new), plus
small additions to `Mac/MacSender.swift`, `Shared/Protocol.swift`,
`Shared/StreamReceiver.swift`, and a new `Shared/CanvasReceiverState.swift`
and `iOS/ReceiverModel.swift`. `PROTOCOL.md` section 11 is the normative
description of everything that crosses the wire.

## Prerequisites

- Xcode (current stable) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node >= 20.10 and [pnpm](https://pnpm.io)
- An iPad on iOS/iPadOS 16.4+, on the same network or a USB cable
- Claude Code 2.1.287 or later (the first version with mods), signed in
  with a claude.ai account or a Claude Console API key. No development
  flag is needed

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

The Mac app supervises this process for you in normal use, from the copy
bundled inside it; the manual `start` above is for developing the daemon on
its own. A Debug build made without pnpm has no bundled server: point its
**Settings ▸ Server build ▸ Choose…** at `DesignCanvas/server/dist/index.js`
(see "First session" below).

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
3. **The iPad now mirrors your Mac's screen.** Whatever is in front on the
   Mac is what the iPad shows and what a sketch is composited onto — no
   extra display appears, and there is nothing to drag anywhere (owner
   decision on PRD open question G1, 2026-09-17). With more than one
   monitor attached, it is the first display macOS reports, normally the
   main one. Two consequences: **everything on
   that screen is streamed to the iPad**, and every round sends the whole
   screen to Claude Code with your sketch over it. Zooming in is for placing
   a stroke; it does not crop what is sent. The mirror keeps the Mac's
   aspect ratio, so expect letterbox bars on the iPad; nothing can be drawn
   on the bars.
4. In the Mac app, click **Open Project…** and choose the repo you want
   Claude Code to work in (or pick it from **Recent projects**).
5. The server and the Claude Code mod ship inside the app, so there is
   nothing to point it at. (A Debug build made without pnpm has no bundled
   server; its Settings window then offers a picker for
   `DesignCanvas/server/dist/index.js`.)
6. Click **Start**. This launches a Terminal window running `claude` in
   your project directory with the Design Canvas mod loaded
   (`--plugin-dir`, pointing inside the app). Nothing is written into your
   project; a `design-canvas` entry left in `.mcp.json` by an earlier
   version is ignored and can be deleted. The first time Claude Code sees a
   folder it asks whether you trust it, and the mod loads only after you
   answer yes. If Claude Code is missing or older than 2.1.287 the app says
   so instead of opening the Terminal.

   You can also skip the button: the first launch asks whether to use
   Design Canvas in every Claude Code session. If you say yes (or turn it
   on later in Settings), running `claude` yourself in any project connects
   that session, and opens the Mac app if it is not running. With several
   sessions connected, the Mac menu and the iPad list them and show which
   one gets the next sketch; click or tap another to switch.
7. **Keep that Terminal window on the mirrored screen** (owner decision
   D20) — the one from step 3, which is where it opens unless you move it
   to another monitor. Claude Code's own permission prompts (tool-use
   confirmations, etc.) still appear there and are answered there. While
   one is open the iPad's session list shows "Waiting for reply at desktop", and nothing more than
   that; keeping the Terminal on the mirrored screen lets you see what it
   is asking. One consequence: since
   the terminal is on the mirrored screen, it is inside every sketch's
   captured frame and composite. A round is always the whole screen, so
   zooming in does not keep it out.
8. On the iPad: tap Draw in the panel, sketch, optionally add a note, and
   tap Send. Two fingers zoom and pan at any time, in Draw Mode too, so you can
   zoom into a detail to draw on it; one finger or the Pencil draws. The composite
   (your sketch flattened over the clean frame) is pushed to Claude Code as
   soon as it's ready. A chip in the top right says "Sending sketch…" until
   the Mac has it, and when Claude Code reports the outcome a notification
   takes its place: applied, failed or needs input, with a PR link when
   there is one. Sketches are worked on one per turn, in order; one sent
   while Claude Code is busy waits on the Mac until its turn. The project
   pill in the top left names the session the next sketch goes to; tap it
   to see every session and what each is doing, or to switch.
9. **To sketch an idea with nothing on screen to point at**, tap **Blank**
   in the iPad's panel instead of **Mirror** (added 2026-10-03). The mirror
   is replaced by a white page with Draw Mode already open; sketch, add a note saying what the
   sketch is for, and tap Send. The round goes to Claude Code the same way,
   described to it as a freehand sketch and not a screenshot, and the page
   is cleared. There is nothing to set on the Mac. The switch is greyed out
   when the Mac app is older than this feature. See
   [`spec/PRD-BlankCanvas.md`](spec/PRD-BlankCanvas.md).
10. **The panel can go to any edge.** Drag it from anywhere on it, or
    long-press it and choose an edge; it stays there across launches.
    The interface is designed in the
    [Figma file](https://www.figma.com/design/N7DN83jg1SrZV9Gx4SIMlq/Design-Canvas-Design)
    (screens and design system, 2026-10-13).

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

- **Mirroring streams the screen at its native pixel size.** That is what
  keeps the picture sharp when you zoom in, but H.264 tops out around 4096×2304: a 5K
  main display at the default quality is rejected by the encoder frame
  after frame (the same ceiling OpenDisplay upstream issue #271 describes
  for a 5K receiver). Until the app has a
  quality control of its own, `defaults write com.designcanvas.mac quality
  balanced` (75%) or `fast` (50%) brings it under the ceiling; relaunch
  afterwards. Debug builds use the `com.designcanvas.mac.debug` domain.
- **Mirror only.** Design Canvas has no extended display: the sender it is
  built on can create one, but here the capture mode is fixed, and a
  stored `mode` default or a `-mode` launch argument is ignored.
- **The blank canvas does not stop the mirror.** While the iPad shows its
  blank page the Mac keeps capturing and streaming the screen underneath,
  so Screen Recording is still needed and the screen still crosses the
  link; only the round itself is free of screen content. One page, white,
  cleared on send — no saved pages (`spec/PRD-BlankCanvas.md`, BG1).
- **A sketch Claude Code does not answer ends as failed, not as a
  timeout.** If its turn ends with no outcome the mod reminds Claude once;
  if there is still none, or you stop the turn, or the session ends, the
  round is marked failed with a line saying which. There is no wall-clock
  timeout: a turn that is still running, including one waiting on a
  permission prompt, keeps its round at `sent`.
- **A machine with many Stop hooks is slower between sketches.** Claude
  Code tells the mod a turn is over only after its Stop hooks have run, so
  a queued sketch starts that much later (8 to 10 s was measured on a Mac
  with five).
- **Organisations can block the mod.** Managed Claude Code settings can
  refuse plugins a user loads. Design Canvas then cannot connect on that
  Mac; the launch stays "Not connected" and the menu says what to look for
  in the Terminal. There is no fallback.
- **Old Claude Code, old iPad app.** Claude Code before 2.1.287 has no
  mods and Start refuses it. An iPad app from before the session list
  keeps working and simply shows no session switcher and no "Waiting for
  reply at desktop".
- **The mod approves one thing on your behalf:** Claude Code reading the
  sketch for the round it is working on, from the store under
  `~/.claude/channels/design-canvas/`. Without that, the read opens a
  permission prompt in Claude Code's default mode (owner decision D22 had
  assumed it would not). Nothing else is approved for you, and a deny rule
  of yours is never overridden.

## Deferred (not built)

Recorded here rather than left silently unbuilt, per the implementation
plan's ruling 9:

- Custom app icons. G18 settled the interface (2026-10-13), not the icons;
  both apps still use the default icon.
- Sparkle update wiring and an appcast feed (no feed exists yet).
- A release/signing/notarization pipeline for the Mac app.
- Metal rendering on the iPad (the current layer-based path already makes
  freeze/Draw Mode fast enough; revisit only if that changes).
- Clear-all in Draw Mode (open design question, G6). Redo is built; the
  panel's trash leaves Draw Mode and throws the sketch away.
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
pnpm --dir DesignCanvas/server test           # daemon, and the Claude Code mod's tests (DesignCanvas/mod/test)
claude plugin validate --strict DesignCanvas/mod   # what Claude Code reads from the mod
pnpm --dir DesignCanvas/server test:channel   # the older channel: two-process topology, real MCP stdio
pnpm --dir DesignCanvas/server test:e2e       # full round lifecycle, no devices
```

A harmless `IDETesting: Result bundle saving failed ... chmod: Operation
not permitted` line after `TEST SUCCEEDED` is sandbox noise in some
environments, not a failure.

## License

GPL-3.0, same as OpenDisplay. Design Canvas is a derivative work built on
OpenDisplay's sender and receiver code; see `LICENSE` at the repo root.
