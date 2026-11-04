# Design Canvas

Design Canvas turns a live mirror of your Mac's screen into a
sketch-and-reply loop with Claude Code: draw on the iPad while it mirrors your Mac, and the
sketch is pushed straight into a running Claude Code session as an
annotated screenshot; the agent's outcome (applied, failed, or a question)
shows back up on the iPad.

It is a pair of apps — a Mac menu-bar app and an iPad app — with their own
Mac-to-iPad link, plus a small local Node daemon and a Claude Code mod, a
plugin that runs inside the Claude Code session. No input is ever forwarded
from the iPad: it is a display and a sketchpad, never a remote control. The
apps build on their own from this folder; their streaming started out as
OpenDisplay's mirroring code, and nothing of OpenDisplay is compiled into
them.

**Status:** the Node half (daemon, mod, the whole round lifecycle) has an
automated end-to-end test that needs no devices — see
[`server/scripts/e2e-round.mjs`](server/scripts/e2e-round.mjs) and
`pnpm --dir server test:e2e` below. Everything that needs a
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
  project.yml, generate.sh   The Xcode project's spec and the script that
                              generates DesignCanvas.xcodeproj from it.
  spec/                      PRD, technical spec, TODOs, the implementation
                              plan, the device checklist, the reply-compliance
                              eval, and wire-protocol.md, the normative
                              description of everything that crosses the
                              Mac-iPad link. The blank canvas surface has its
                              own pair, PRD-BlankCanvas.md and
                              technical_doc-BlankCanvas.md (2026-10-03).
  Shared/                    Foundation-only code compiled into both apps and
                              the hostless test bundle.
    WireFrame.swift             Frames on the socket: [length][kind][body],
                                 messages as JSON plus a binary attachment.
    VideoPacket.swift           One encoded video frame and its frame number.
    LinkMessages.swift          hello, status, bye: what keeps a link up.
    CanvasMessages.swift        The CanvasWire constants and the canvas
                                 messages (freeze, annotation, rounds, ...).
    DrawModeStateMachine.swift  The iPad's Draw Mode state machine, as a pure
                                 struct.
    Log.swift                   The log both apps write.
  Mac/
    Stream/                    The Mac's end of the link: ScreenCapture (the
                                main display, captured once for every iPad),
                                VideoEncoder, MirrorLink (one per iPad, across
                                reconnects), MirrorEngine (which iPads to
                                serve), DeviceWatcher and Usbmux (finding them).
    Engine/                    The canvas engine: FrameRing, Compositor,
                                DaemonClient, CanvasSession (one per iPad),
                                CanvasHub, UploadPipeline, SSEParser,
                                DeviceDirectory (who to connect),
                                StreamGeometry. Hostless-testable.
    App/                       The menu-bar app shell: AppModel, MenuBarView,
                                DaemonSupervisor, ClaudeLauncher,
                                ClaudeSettingsManager, SessionStateClassifier,
                                ProcessResetService, ProjectRecents,
                                ScreenRecordingPermission, SenderEngine (the
                                seam the shell talks to).
    DesignCanvasMac.entitlements
  iOS/
    Stream/CanvasReceiver.swift  The iPad's end of the link: listen, adopt the
                                Mac, decode, freeze. No UIKit, so the Mac test
                                bundle runs it.
    DesignCanvasApp.swift, ReceiverController.swift (the scene and lock
    lifecycle), CanvasScreen.swift (the screen and its chrome),
    CanvasVideoView.swift, SketchCanvas.swift, ControlPanel.swift (the
    tool panel), DrawingButton.swift (start and end drawing),
    ProjectPill.swift (the session pill and menu), WindowSwitcher.swift
    (the window button and menu), GlassMorph.swift (how a control grows
    into its menu), FrozenFrameIndicator.swift (the held picture's print),
    SentSketchCard.swift (the sketch seen leaving), ReplyNotificationCard.swift,
    ConnectionStatusView.swift (connection details), DiagnosticsLogView.swift
    (the connection log), SetupGuideView.swift (the waiting screen's setup
    steps), CanvasColors.swift (the colour tokens), ReceiverAdapter.swift,
    Assets.xcassets (the whiteboard icon)
    Logic/                     CanvasModel.swift, ZoomModel.swift,
                                PanelDock.swift, TopBarLayout.swift,
                                BottomBarLayout.swift, ReplyNotification.swift,
                                SetupGuide.swift (the prompt it copies) —
                                the pure, testable logic behind the views
                                above.
    DesignCanvasiOS.entitlements
  Tests/                       The hostless XCTest bundle, `DesignCanvasTests`,
                                including LinkLoopbackTests: both ends of the
                                link over a real loopback socket.
  mod/                         The Claude Code mod: one plain-JavaScript hooks
                                module, bundled into the Mac app at build time
                                (tools/bundle-mod.sh). Its tests run with the
                                server's.
  server/                      The Node package: daemon (--http), which also
                                keeps the list of connected sessions, and the
                                older channel (--channel). See server/README.md
                                for its own module map and hard rules.
```

Nothing outside this folder is compiled into either app.
[`spec/wire-protocol.md`](spec/wire-protocol.md) is the normative
description of everything that crosses the Mac-iPad link.

## Prerequisites

- Xcode (current stable) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node >= 20.10 and [pnpm](https://pnpm.io)
- An iPad on iOS/iPadOS 16.4+, on the same network or a USB cable
- Claude Code 2.1.287 or later (the first version with mods), signed in
  with a claude.ai account or a Claude Console API key. No development
  flag is needed

## Build and run

Everything below runs from this folder (`DesignCanvas/`). The Xcode project
is generated, not checked in:

```sh
./generate.sh
```

Regenerate after any `project.yml` change, or after adding or removing a
file; never edit `DesignCanvas.xcodeproj` directly. `generate.sh` reads
`DEVELOPMENT_TEAM` from a `.env` here or at the repo root.

### The daemon (Node)

```sh
pnpm --dir server install
pnpm --dir server build
pnpm --dir server start          # designtool --http, on 127.0.0.1:47100
```

The Mac app supervises this process for you in normal use, from the copy
bundled inside it; the manual `start` above is for developing the daemon on
its own. A Debug build made without pnpm has no bundled server: point its
**Settings ▸ Server build ▸ Choose…** at `DesignCanvas/server/dist/index.js`
(see "First session" below).

### The Mac app

```sh
xcodebuild build \
  -project DesignCanvas.xcodeproj \
  -scheme DesignCanvasMac \
  -destination 'platform=macOS'
```

Or open `DesignCanvas.xcodeproj` in Xcode and run the `DesignCanvasMac`
scheme. It needs Screen Recording (granted from the app's menu — it is the
*only* TCC permission it asks for; it never requests Accessibility,
because it never injects input).

### The iPad app

```sh
xcodebuild build \
  -project DesignCanvas.xcodeproj \
  -scheme DesignCanvasiOS \
  -destination 'generic/platform=iOS'
```

Or open the project in Xcode, select the `DesignCanvasiOS` scheme and a
real device or simulator, and run. The Mac app and the iPad app speak one
wire version and must be built from the same checkout; a mismatched pair
says which one to update.

## First session

1. Launch the Mac app. Grant Screen Recording if it isn't already granted
   (this needs one relaunch to take effect).
2. Open the Design Canvas app on the iPad and leave it open. The iPad is
   the listener: it has no list of Macs and nothing to pick. Over **USB**,
   plugging the cable in connects on its own. Over **WiFi**, the iPad
   appears under **iPads** in the Mac app's menu — click **Connect** next
   to it. The first time, by cable or WiFi, the two pair: both screens
   show the same six-digit code; check it matches and tap **Pair** on both.
   From then on the Mac reconnects that iPad on its own, over either;
   **Disconnect** stops both the session and the auto-reconnect. If the
   iPad is already mirroring another Mac, it asks before it switches (see
   "Security note"). Until a Mac connects, the iPad's waiting screen lists
   these steps: install the Mac app, install the Claude Code mod (step 6),
   connect the iPad.
3. **The iPad now mirrors your Mac's screen.** Whatever is in front on the
   Mac is what the iPad shows and what a sketch is composited onto — no
   extra display appears, and there is nothing to drag anywhere (owner
   decision on PRD open question G1, 2026-09-17). With more than one
   monitor attached, it is the main display (the one with the menu bar). Two consequences: **everything on
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

   The iPad's waiting screen offers the same thing as a prompt: tap
   **Copy** there and paste it into Claude Code on the Mac (Handoff carries
   the clipboard across). Claude Code then adds the mod inside the
   installed app to `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json`,
   which is exactly the entry the switch writes, so Settings shows it on
   and turning it off there undoes it. The same step also says the mod can
   be installed from the marketplace; there is no listing yet (see
   [`spec/TODOS.md`](spec/TODOS.md)), so for now that route leads nowhere.
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
8. On the iPad: tap the round pencil button at the bottom left, sketch,
   optionally add a note in the field at the top right, and tap Send. Two fingers zoom and pan at any time, in Draw Mode too, so you can
   zoom into a detail to draw on it; one finger or the Pencil draws. The composite
   (your sketch flattened over the clean frame) is pushed to Claude Code as
   soon as it's ready; on the iPad the sketch is seen flying into the
   session pill. When Claude Code reports the outcome a notification
   appears at the top right: applied, failed or needs input, with a PR
   link when there is one. To stop drawing without sending, tap the cross
   where the pencil was; with ink on the page it asks first, since the
   sketch is not kept. Sketches are worked on one per turn, in order; one sent
   while Claude Code is busy waits on the Mac until its turn. The session
   pill in the top left names the session the next sketch goes to; tap it
   to see every session and what each is doing, or to switch.
9. **To sketch an idea with nothing on screen to point at**, tap the
   window button under the session pill and pick **Whiteboard** (added
   2026-10-03). The mirror is replaced by a white page that is always ready
   to draw; sketch, add a note saying what the sketch is for, and tap Send.
   The round goes to Claude Code the same way, described to it as a
   freehand sketch and not a screenshot, and the page is cleared. Pick your
   Mac in the same menu to go back. There is nothing to set on the Mac.
   Whiteboard is greyed out when the Mac app is older than this feature. See
   [`spec/PRD-BlankCanvas.md`](spec/PRD-BlankCanvas.md).
10. **The tool panel can go to any edge.** While drawing, drag it from
    anywhere on it to the edge you want; it stays there across launches.
    The interface is designed in the
    [Figma file](https://www.figma.com/design/N7DN83jg1SrZV9Gx4SIMlq/Design-Canvas-Design)
    (screens and design system, 2026-10-13; v3.1, 2026-11-02).

## Security note

**The Mac and the iPad pair once, and every session is authenticated and
encrypted**, over USB and WiFi alike. The pattern is HomeKit's and AirPlay
2's (`spec/wire-protocol.md` section 5.7):

- **Pairing.** The first time a Mac and an iPad meet, both screens show the
  same six-digit code. Check that they match and tap **Pair** on both; if
  they differ, cancel: something is in between. Each device then remembers
  the other's key, in its Keychain.
- **Every session after that** proves both keys and encrypts everything,
  the screen included. A device that cannot prove a paired key gets nothing:
  no picture, no sketches. A paired iPad reconnects by itself over USB or
  WiFi; one that fails its proof on WiFi shows **Not paired** in the menu
  rather than starting a new pairing on its own.
- **Starting a pairing takes intent:** plugging the iPad in, or clicking
  **Connect** for it. On the iPad, after a pairing is cancelled or times
  out, WiFi requests are turned away for a minute without asking.
- **Switching Macs.** While the iPad mirrors one Mac, another paired Mac
  over WiFi never takes over silently: the iPad asks "Switch Macs?" first.
  Plugging a cable in takes over at once.
- **Forget** a device on either side (the Mac's Details window, the iPad's
  Connection details) and it has to pair again.

What pairing does not cover: the iPad's name and the Mac's name are only
what each device calls itself, so compare the code, not the name. And the
Mac app trusts everything else running on the Mac (below).

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

- **Mirroring streams the screen at its native pixel size, up to what H.264
  takes.** That keeps the picture sharp when you zoom in. A display bigger
  than about 4096×2304 (a 5K one) is streamed scaled down to fit, keeping
  its shape. `defaults write com.designcanvas.mac quality balanced` (75%) or
  `fast` (50%) lowers it further for a slow WiFi; relaunch afterwards. Debug
  builds use the `com.designcanvas.mac.debug` domain.
- **Mirror only.** Design Canvas mirrors the main display and never creates
  a display of its own. The screen is captured only while an iPad is
  mirroring it.
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
- **Old Claude Code, mismatched apps.** Claude Code before 2.1.287 has no
  mods and Start refuses it. The Mac and iPad apps must speak the same wire
  version: a pair that does not is not connected, and says which side to
  update. That includes any iPad or Mac app from before Design Canvas had
  its own link, or before pairing (both 2026-11-03).
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
- Automated device-level end-to-end testing — it needs real hardware.
  [`spec/device-checklist.md`](spec/device-checklist.md) is the manual
  checklist that stands in for it.

See [`spec/TODOS.md`](spec/TODOS.md) for the fuller backlog (encrypted WiFi
transport, an MCP tool that returns the composite as an image block,
batched-turn measurement, a pending-round TTL) and
[`spec/technical_doc.md`](spec/technical_doc.md) section 10 for every
decision and open question behind this feature.

## Verifying a change

From this folder:

```sh
# Regenerate after any project.yml change or added/removed file
./generate.sh

# Swift tests (hostless bundle) — the DesignCanvasMac scheme also builds the Mac app
xcodebuild test  -project DesignCanvas.xcodeproj -scheme DesignCanvasMac -destination 'platform=macOS' -derivedDataPath ../build/dc CODE_SIGNING_ALLOWED=NO

# The iPad app
xcodebuild build -project DesignCanvas.xcodeproj -scheme DesignCanvasiOS -destination 'generic/platform=iOS' -derivedDataPath ../build/dc CODE_SIGNING_ALLOWED=NO

# Node
pnpm --dir server install
pnpm --dir server typecheck
pnpm --dir server test           # daemon, and the Claude Code mod's tests (mod/test)
claude plugin validate --strict mod   # what Claude Code reads from the mod
pnpm --dir server test:channel   # the older channel: two-process topology, real MCP stdio
pnpm --dir server test:e2e       # full round lifecycle, no devices
```

The `DesignCanvas` scheme runs the tests without building either app.
Nothing here touches the OpenDisplay apps in the rest of the repo.

A harmless `IDETesting: Result bundle saving failed ... chmod: Operation
not permitted` line after `TEST SUCCEEDED` is sandbox noise in some
environments, not a failure.

## License

GPL-3.0, same as OpenDisplay. Design Canvas is a derivative work: parts of
its streaming code (the usbmuxd client, the encoder settings, the receiver's
lifecycle handling) are adapted from OpenDisplay's sender and receiver; see
`LICENSE` at the repo root.
