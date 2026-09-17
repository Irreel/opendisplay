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
| 1 | **Pairing** | WiFi: the iPad appears in the Mac's device list via Bonjour and connects with one tap the first time (trust-on-first-use); reconnecting later needs no further prompt. USB: plugging the cable connects with no discovery step at all. |
| 2 | **Mirror** | The iPad shows a live, low-latency mirror of the Mac's virtual display. Tap and drag on the iPad's screen and confirm nothing moves, clicks, or scrolls on the Mac — a canvas session forwards no input in either direction. |
| 3 | **Zoom** | Pinch-to-zoom and pan on the iPad are smooth, local, and view-only: the Mac's display and the live mirror are unaffected by zooming in or out. |
| 4 | **Freeze exactness** | Point the mirrored display at something moving (the clock/spinner). Enter Draw Mode at a moment you can identify precisely (e.g. "the second hand crosses 12"). After the round completes, open `~/.claude/channels/design-canvas/annotations/<id>/screenshot.png` for that annotation and confirm it shows that exact moment — not a frame noticeably before or after. |
| 5 | **Zoomed crop** | Pinch-zoom into a small region *before* entering Draw Mode, then sketch and send. Confirm `composite.png` and `sketch.png` in that annotation's store folder are cropped to the zoomed region (not the full frame), and the sketch lines up with what was drawn on-screen. |
| 6 | **Done timing** | Tap Done and time how long until the round shows `sent` (the channel notification firing, visible via the iPad's round status or the Mac app). Target: under 1 s on a reasonably fast network (PRD success metric). |
| 7 | **Reply shown** | Once Claude Code calls `design_canvas_reply`, the iPad's Agent Replies view shows the status (`applied` / `failed` / `needs_input`), the message, and the PR link when one was given — without needing to leave and reopen the app. |
| 8 | **Link loss mid-upload, with resend** | Draw a sketch, tap Done, and kill the link before the upload completes (unplug the USB cable, or turn off WiFi on the iPad). Confirm the sketch is not lost: Draw Mode enters RETRY, keeps the strokes, and resends automatically once the link comes back (the next successful `hello`). |
| 9 | **Rotation in Draw Mode** | Rotate the iPad while mid-sketch in Draw Mode. Confirm the strokes are kept, the session returns to LIVE (not silently discarded), and re-entering Draw Mode lets you finish and send. |
| 10 | **Reconnect snapshot** | With at least one round already replied, force a fresh reconnect (quit and relaunch the iPad app, or toggle airplane mode). Confirm the `rounds` snapshot sent after the new `hello` shows that round's correct final status immediately, with no live push needed. |
| 11 | **Both connection dots** | The iPad's Connection Status view shows two distinct indicators — the Mac↔iPad wire and the Mac↔Claude Code channel — plus the selected project name or "unselected". Confirm each reflects reality: detaching the channel on the Mac (Reset, or quitting Claude Code) changes the channel dot; moving out of WiFi range (or unplugging USB) changes the wire dot. |

## Results

| Date | Tester | Transport | Build/commit | Pass | Fail | Notes |
|---|---|---|---|---|---|---|
| | | USB | | | | |
| | | WiFi | | | | |

Log a fail with enough detail to file an issue: which check, which step of
the check, what was expected vs. observed, and — if it's plausibly a wire
bug rather than a UI bug — the relevant lines from the daemon's log
(`~/Library/Logs/DesignCanvas/server.log` by default, or wherever
`DESIGN_CANVAS_LOG_PATH` points) and the Mac app's console output.
