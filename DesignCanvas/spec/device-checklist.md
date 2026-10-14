# Design Canvas device checklist

Manual pass on real hardware. Nothing in this file is automated —
device-level end-to-end testing is explicitly deferred (see
`DesignCanvas/README.md` "Deferred"); this checklist is what stands in for
it until it exists. The Node half of the round lifecycle already has an
automated proof with no devices: `pnpm --dir DesignCanvas/server
test:e2e`. This file is about everything that proof cannot reach: the
actual OpenDisplay wire, the actual camera-to-screen video path, and the
actual PencilKit/UIKit surface on a real iPad.

Run the whole list once over **USB** and once over **WiFi** — most checks
apply to both transports, but a bug in one binding rarely shows up in the
other.

## Setup

- A Mac running the Design Canvas Mac app (Screen Recording granted). The
  daemon and the Claude Code mod ship inside the app; only a Debug build
  made without pnpm needs **Settings ▸ Server build ▸ Choose…** pointed at
  `DesignCanvas/server/dist/index.js`.
- A real iPad running the Design Canvas iPad app, on iOS/iPadOS 16.4+.
- A real Claude Code session with the Design Canvas mod, started from the
  Mac app (**Open Project…**, then **Start**) or, with the every-session
  option on, by running `claude` in the project.
- Something with visible motion to freeze against (a video, a spinner, or
  a digital clock with seconds) for the freeze-exactness check.

## Checklist

| # | Check | How to verify |
|---|---|---|
| 1 | **Pairing** | WiFi: the iPad appears under **iPads** in the Mac app's menu via Bonjour, with a **Connect** button; clicking it once starts the session, and relaunching the Mac app reconnects that iPad with no further click (the first connect is what makes the sender remember it). **Disconnect** ends the session and stops the auto-reconnect. USB: plugging the cable connects with no discovery step and no click at all. |
| 2 | **Mirror** | The iPad shows a live, low-latency mirror of the Mac's own screen — whatever is in front, letterboxed to the Mac's aspect ratio, with no extra display appearing in System Settings ▸ Displays. Tap and drag on the iPad's screen and confirm nothing moves, clicks, or scrolls on the Mac — a canvas session forwards no input in either direction. |
| 3 | **Zoom** | Pinch-to-zoom and pan on the iPad are smooth, local, and view-only: the Mac's display and the live mirror are unaffected by zooming in or out. |
| 4 | **Freeze exactness** | Put something moving on the Mac's screen (the clock/spinner). Enter Draw Mode at a moment you can identify precisely (e.g. "the second hand crosses 12"). After the round completes, open `~/.claude/channels/design-canvas/annotations/<id>/screenshot.png` for that annotation and confirm it shows that exact moment — not a frame noticeably before or after. |
| 5 | **Zoom in Draw Mode** (changed 2026-10-09; was "Zoomed crop") | Enter Draw Mode, then pinch and pan with two fingers: the frozen frame zooms and pans, and the fingers leave no dot or line behind. Draw at one zoom, zoom out and back in, and confirm every stroke stays on the part of the frame it was drawn on. Draw with the Pencil while your hand rests on the screen and confirm the picture does not zoom and the stroke is not cut short. Try to draw on a letterbox bar: nothing appears. Send, and confirm `composite.png` in that annotation's store folder is the full frame, not cropped to the zoomed region, with each stroke where it was drawn, and that the Claude Code event reads "Zoom region: full frame". Repeat once after zooming in *before* entering Draw Mode: the round is still the full frame. |
| 6 | **Send timing** | Tap Send and time how long until the round reaches Claude Code (the event appears in the Claude Code terminal, or the iPad's "Sending sketch…" chip goes away). Target: under 1 s on a reasonably fast network (PRD success metric). |
| 7 | **Reply shown** (changed 2026-10-13; was the Agent Replies view) | Once Claude Code reports the outcome, a notification appears in the iPad's top-right corner without leaving or reopening the app: **Applied** (with the note, and "Open pull request" when a PR link was given, which opens it), **Couldn't apply** with Claude's message, or **Claude needs a reply at the desktop**. Applied leaves on its own after about 5 s; the other two stay until tapped or swiped away. With VoiceOver on, the notification is read out when it appears. |
| 8 | **Link loss mid-upload, with resend** | Draw a sketch, tap Send, and kill the link before the upload completes (unplug the USB cable, or turn off WiFi on the iPad). Confirm the sketch is not lost: Draw Mode enters RETRY, keeps the strokes, and resends automatically once the link comes back (the next successful `hello`). |
| 9 | **Rotation in Draw Mode** | Rotate the iPad while mid-sketch in Draw Mode. Confirm the strokes are kept, the session returns to LIVE (not silently discarded), and re-entering Draw Mode lets you finish and send. |
| 10 | **Reconnect snapshot** | With at least one round already replied, force a fresh reconnect (quit and relaunch the iPad app, or toggle airplane mode). Confirm the `rounds` snapshot sent after the new `hello` shows that round's correct final status immediately, with no live push needed. |
| 11 | **Connection state** (changed 2026-10-13; was "Both connection dots") | With no Mac connected the iPad shows only the waiting screen; connecting replaces it with the mirror. The project pill names the target session's folder. Quit Claude Code (or Reset on the Mac) and confirm the pill turns to "No session" with an orange dot and Draw is disabled. With two or more sessions, tap the pill: every session is listed with Ready, Busy or Waiting for reply at desktop, the target has a tick, and picking another moves the tick and the pill. End the target session while others remain and confirm the pill asks to "Choose a session" and Send waits for the pick. "Connection details…" opens the sheet with the connection parameters and the log. Then, with a Claude Code session the app did **not** start holding the channel, confirm the Mac menu says **Another session** in orange. |
| 12 | **Blank canvas** (added 2026-10-03, `PRD-BlankCanvas.md`) | With a session connected, the iPad's panel shows **Mirror** and **Blank**. Tap Blank: the mirror is replaced by a white page filling the screen, and nothing changes in the Mac app's menu. The drawing tools appear with that same tap, with no freeze delay and without tapping Draw. Tap Cancel (the ✕) and confirm the panel comes back on the white page, with Draw re-entering Draw Mode. Then sketch, add a note, tap Send. Confirm: the page clears; the send chip shows and then the reply notification; in the Claude Code terminal the event reads "New sketch from iPad (blank canvas)" with no "Zoom region" line; `composite.png` and `screenshot.png` in that annotation's store folder are the strokes on white and a plain white page, with no screen content, and the strokes are neither stretched nor offset. Switch back to Mirror and confirm the live picture and a normal mirror round still work. Quit and reopen the iPad app: the last-chosen surface is restored once the Mac reconnects. |
| 13 | **Blank canvas, link loss** | On the Blank surface, draw, tap Send, and cut the link before the upload completes. Confirm the chip reads "Sketch kept — will resend", the iPad falls back to showing Mirror/waiting while disconnected, and after reconnecting exactly one round arrives, still as a blank-canvas sketch. |
| 14 | **Panel docking** (added 2026-10-13) | Drag the panel from anywhere on it to each of the four edges, between sketches and in Draw Mode. While dragging, the grabber shows on the side facing the edge the panel started on, and hides on release; the panel snaps to the edge nearest the drop. On a side edge its controls run top to bottom. Long-press the panel: a menu offers Move to top, bottom, left and right, with a tick on the current one, and each works. Quit and relaunch the app: the panel is where it was left. With VoiceOver, the panel's position control offers the same four actions. |
| 15 | **Top bar layout** (added 2026-10-13) | Top-docked, in Draw Mode, in landscape: the palette sits in the top row between Cancel and the note field, level with them, and nothing overlaps. In portrait it takes the row below. Type a long note: the field grows and stops before the palette. With a reply notification showing, nothing overlaps the panel in either orientation. |
| 16 | **Legibility** (added 2026-10-13) | In light and in dark appearance, over a dark mirror and over a white one, read every piece of chrome: the pill, the panel, the note placeholder, the send chip, the notification and the session list. Nothing is faint or unreadable. Run once below iOS 26 if a device is available, where the glass falls back to the frosted material. |

## Reporting a failure

Log a fail with enough detail to file an issue: which check, which step of
the check, what was expected vs. observed, and — if it's plausibly a wire
bug rather than a UI bug — the relevant lines from the daemon's log
(`~/Library/Logs/DesignCanvas/server.log` by default, or wherever
`DESIGN_CANVAS_LOG_PATH` points) and the Mac app's own log,
`~/Library/Logs/OpenDisplay/opendisplay.log`. That file is shared with
OpenDisplay and with the unit tests, and fills with `DaemonClient: rounds
stream` lines whenever the daemon is down, so read it through
`grep -v "DaemonClient: rounds stream"`.
