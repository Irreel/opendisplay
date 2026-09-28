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
other. Record pass/fail and notes per transport in the table below; append
a dated row per run rather than overwriting the last one.

## Setup

- A Mac running the Design Canvas Mac app (Screen Recording granted) and
  the daemon built and pointed at from "Set server build…".
- A real iPad running the Design Canvas iPad app, on iOS/iPadOS 16.4+.
- A real Claude Code session started from the Mac app ("Start session"),
  attached to a real project.
- Something with visible motion to freeze against (a video, a spinner, or
  a digital clock with seconds) for the freeze-exactness check.

## Checklist

| # | Check | How to verify |
|---|---|---|
| 1 | **Pairing** | WiFi: the iPad appears under **iPads** in the Mac app's menu via Bonjour, with a **Connect** button; clicking it once starts the session, and relaunching the Mac app reconnects that iPad with no further click (the first connect is what makes the sender remember it). **Disconnect** ends the session and stops the auto-reconnect. USB: plugging the cable connects with no discovery step and no click at all. |
| 2 | **Mirror** | The iPad shows a live, low-latency mirror of the Mac's own screen — whatever is in front, letterboxed to the Mac's aspect ratio, with no extra display appearing in System Settings ▸ Displays. Tap and drag on the iPad's screen and confirm nothing moves, clicks, or scrolls on the Mac — a canvas session forwards no input in either direction. |
| 3 | **Zoom** | Pinch-to-zoom and pan on the iPad are smooth, local, and view-only: the Mac's display and the live mirror are unaffected by zooming in or out. |
| 4 | **Freeze exactness** | Put something moving on the Mac's screen (the clock/spinner). Enter Draw Mode at a moment you can identify precisely (e.g. "the second hand crosses 12"). After the round completes, open `~/.claude/channels/design-canvas/annotations/<id>/screenshot.png` for that annotation and confirm it shows that exact moment — not a frame noticeably before or after. |
| 5 | **Zoomed crop** | Pinch-zoom into a small region *before* entering Draw Mode, then sketch and send. Confirm `composite.png` and `sketch.png` in that annotation's store folder are cropped to the zoomed region (not the full frame), and the sketch lines up with what was drawn on-screen. Repeat once with the zoomed region touching a letterbox bar: the crop must still line up, because zoom coordinates are relative to the picture, not the iPad's screen. |
| 6 | **Done timing** | Tap Done and time how long until the round shows `sent` (the channel notification firing, visible via the iPad's round status or the Mac app). Target: under 1 s on a reasonably fast network (PRD success metric). |
| 7 | **Reply shown** | Once Claude Code calls `design_canvas_reply`, the iPad's Agent Replies view shows the status (`applied` / `failed` / `needs_input`), the message, and the PR link when one was given — without needing to leave and reopen the app. |
| 8 | **Link loss mid-upload, with resend** | Draw a sketch, tap Done, and kill the link before the upload completes (unplug the USB cable, or turn off WiFi on the iPad). Confirm the sketch is not lost: Draw Mode enters RETRY, keeps the strokes, and resends automatically once the link comes back (the next successful `hello`). |
| 9 | **Rotation in Draw Mode** | Rotate the iPad while mid-sketch in Draw Mode. Confirm the strokes are kept, the session returns to LIVE (not silently discarded), and re-entering Draw Mode lets you finish and send. |
| 10 | **Reconnect snapshot** | With at least one round already replied, force a fresh reconnect (quit and relaunch the iPad app, or toggle airplane mode). Confirm the `rounds` snapshot sent after the new `hello` shows that round's correct final status immediately, with no live push needed. |
| 11 | **Both connection dots** | The iPad's Connection Status view shows two distinct indicators — the Mac↔iPad wire and the Mac↔Claude Code channel — plus the selected project name or "unselected". Confirm each reflects reality: detaching the channel on the Mac (Reset, or quitting Claude Code) changes the channel dot; moving out of WiFi range (or unplugging USB) changes the wire dot. |

## Results

| Date | Tester | Transport | Build/commit | Pass | Fail | Notes |
|---|---|---|---|---|---|---|
| 2026-09-17 | owner | USB | `72104fe`, then `c9f59d2` | 1 (USB half) | — | **Not a checklist run** — first bring-up. USB auto-connect works once a flaky cable was replaced (its signature: `usbmux attached` then `usbmux detached` within ~300 ms, repeatedly). The iPad showed the Mac's stream, at the time as an extended display. Found and fixed: `pnpm start` never launched the daemon; macOS never brought the virtual displays online, so the first session showed nothing. Decided from these sessions: mirror only. Checks 2–11 not run; the mirror-only build has not been on the iPad yet. |
| | | USB | | | | |
| | | WiFi | | | | |

Log a fail with enough detail to file an issue: which check, which step of
the check, what was expected vs. observed, and — if it's plausibly a wire
bug rather than a UI bug — the relevant lines from the daemon's log
(`~/Library/Logs/DesignCanvas/server.log` by default, or wherever
`DESIGN_CANVAS_LOG_PATH` points) and the Mac app's own log,
`~/Library/Logs/OpenDisplay/opendisplay.log`. That file is shared with
OpenDisplay and with the unit tests, and fills with `DaemonClient: rounds
stream` lines whenever the daemon is down, so read it through
`grep -v "DaemonClient: rounds stream"`.
