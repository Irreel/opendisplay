# PRD: Design Canvas

**Status:** Draft v0.10, 2026-10-13 (v0.9 was 2026-10-09; v0.8 was 2026-10-03; v0.7 was 2026-09-22; v0.6 was 2026-09-18, after the first hardware sessions; v0.5 was 2026-09-16, after the engineering review). v0.10 records the redesign of the iPad interface (owner, 2026-10-13, in the Figma file below): a project pill and its session list replace the connection status panel, one floating panel that can be docked to any screen edge holds the controls, Send replaces Done, and a notification replaces the list of agent replies (section 6; P1 to P4, M2, M5, M8; G18 decided). v0.9 lets the designer zoom and pan inside Draw Mode and makes every mirror round the whole frame (owner, 2026-10-09, after device testing; C2, M5, section 9). v0.8 scopes the mirror requirements to the mirror surface, now that the iPad also has a blank canvas surface; that surface is specified in its own document, `PRD-BlankCanvas.md`, and nothing about it is repeated here. v0.7 added the Mac-app information architecture from the board after the second dogfooding round. v0.6 recorded the decision on G1: the iPad mirrors the Mac's own screen, and there is no extended display. Product requirements only; the technical specification is in `technical_doc.md`.
**Owner:** AntheaZ
**Sources:** [FigJam board "Design Canvas"](https://www.figma.com/board/eMxEcxvPAeNtaoWbsKaa6S/Design-Canvas?node-id=0-1); [Figma file "Design Canvas Design"](https://www.figma.com/design/N7DN83jg1SrZV9Gx4SIMlq/Design-Canvas-Design) (the iPad design system and screens, 2026-10-13); the ai.cst.2 repo (the earlier build we dogfooded and pivoted from); OpenDisplay.

## 1. One-liner

Design Canvas turns an iPad into a live, drawable view of the feature running on a designer's Mac. The designer sketches review feedback on the live preview, the sketch goes straight into their running Claude Code session, Claude Code edits the source and reports back, and the designer sees the fix on the same iPad.

## 2. Problem

Human-AI collaboration is text-first, but design review is visual. Describing "move this 8px left, make the hierarchy read like that" in words is slow and lossy.

Dogfooding ai.cst.2 showed:

- Models read rough doodles on a screenshot well, and it is much faster than typing.
- Free-form drawing is not always the natural gesture; some feedback wants "select an element, adjust it."
- The loop was too long: capture a screenshot, draw on the iPad, check the laptop, capture again. Manual capture killed it.

Design Canvas removes capture by mirroring the Mac live, keeps ai.cst.2's agent integration, and adds a reply so the outcome reaches the iPad.

## 3. Goals and non-goals

**Goals (MVP)**

1. Zero-capture loop. The designer never takes or transfers a screenshot.
2. Native drawing with Apple Pencil: pen, eraser, undo, color, region zoom.
3. One tap ("Send") sends the sketch plus optional text into the running Claude Code session. No prompt typed on the Mac.
4. Claude Code's outcome (applied, failed, needs input, PR link) shows on the iPad.
5. The fix is visible on the same iPad without leaving the app.
6. Connection health for both hops (iPad to Mac, Mac to Claude Code) is visible at a glance: the iPad shows a waiting screen while it has no Mac, and names the Claude Code session the next sketch goes to.
7. One pairing, the one OpenDisplay already has.

**Non-goals (MVP)**

- Stack: a saved queue of unsent or failed sketches for batch review. Batching encourages context switching; deprioritized on the board.
- Element selection and property panels.
- Any control of the Mac from the iPad. The iPad is view-and-draw only; no touch, scroll, or Pencil input is forwarded. This also means the Mac app never asks for the Accessibility permission.
- Agents other than Claude Code.
- Any LLM call or source edit made by Design Canvas itself. Claude Code is the agent; Design Canvas is plumbing.
- A conversational two-way channel or permission relay. The MVP reply is one structured status per sketch.

## 4. User and story

**Primary user:** a product designer who ships code with Claude Code and reviews features running locally on their Mac.

**Amy:** opens the Design Canvas menu-bar app, picks her project, taps Start session. A terminal opens with Claude Code attached. Her iPad, already paired from OpenDisplay, mirrors the preview. She zooms into the header, enters draw mode, circles a misaligned icon, draws an arrow, types "align with the title baseline", taps Send. Claude Code reads the sketch, edits the source, replies "applied" with a PR link. The mirror updates, Amy sees the fix and a notification saying it was applied on her iPad, and starts the next round.

## 5. Flow

**Setup, once.** Install both apps. Pair over OpenDisplay (Bonjour or USB, no code). Pick the project in the menu-bar app. Tap Start session; the app launches Claude Code with the Design Canvas channel attached.

**Each round.**

1. The iPad mirrors the Mac.
2. Pinch to zoom into a region.
3. Enter Draw Mode. The iPad freezes on the current frame; the Mac captures a clean still of the same moment.
4. Draw with the Pencil or one finger. Two fingers zoom and pan the frozen frame at any time, to work on a detail and come back out. Optionally type a note.
5. Tap Send. Draw Mode exits, sync resumes, and the sketch is sent over the whole frame, whatever the zoom was.
6. Claude Code receives it, edits the source, replies with a status.
7. The live mirror shows the change; a notification on the iPad says what Claude Code did with the round.

## 6. Information architecture

The Mac-app tree is from the board (re-read 2026-09-22), new there since the second dogfooding round. The iPad tree was redesigned on 2026-10-13 in the style of Apple Freeform; the screens and the design system are in the [Figma file](https://www.figma.com/design/N7DN83jg1SrZV9Gx4SIMlq/Design-Canvas-Design). Stack is drawn on the board but deprioritized for the MVP.

**iPad**

```
Waiting screen: fills the iPad while no Mac is connected
Canvas: the live mirror or the blank page (two fingers zoom and pan)
Top bar
 ├─ Project pill: the Claude Code session the next sketch goes to, or "No session" / "Choose a session"
 │    └─ tap ──▶ session list
 │         ├─ each session: folder, Ready / Busy / Waiting for reply at desktop, a tick on the target
 │         └─ "Connection details…" ──▶ connection parameters, errors and the log
 ├─ Send chip, between sketches: "Sending sketch…", or "Sketch kept — will resend" with a way to give it up
 └─ Reply notification, top right: applied, failed or needs input, with a PR link when present
Panel: floats; drag it to any screen edge, or long-press it for Move to top, bottom, left, right
 ├─ Between sketches: Mirror, Blank, Draw
 └─ In Draw Mode: undo, redo, pen, eraser, five inks, throw the sketch away
Draw Mode top bar: Cancel (keeps the strokes), "Add a note" (optional), Send
Stack (deprioritized)
 ├─ Thumbnails of saved sketches; failed sends marked with a badge
 └─ "Send"
```

**Mac app (menu bar)**

```
Connection status
 ├─ iPad: connected or not
 └─ Claude Code: channel attached or not
Current project: folder name and directory
Coding-agent client name (claude, codex, …) — future, not in the MVP
```

The three Mac items map onto existing requirements: connection status onto D7 (session state) and D2, the project row onto D3. The client name is listed under future versions with the other agents.

## 7. Requirements

IDs are referenced from the technical doc. C1, C2, M1, M7 and D9 describe the mirror surface; the blank canvas surface (2026-10-03) has its own requirements, B1 to B8, in `PRD-BlankCanvas.md`. Every other row applies to both surfaces.

**Mac**

| ID | Requirement |
|---|---|
| D1 | Mirror the Mac's main display to the iPad over USB or WiFi (OpenDisplay's mirror capture). No extra display is created, and there is no extended-display mode |
| D2 | Menu-bar app keeps the local service running while open |
| D3 | Menu-bar app picks the project, configures it, and launches Claude Code with the channel; never force-kills Claude Code |
| D4 | Store every sketch and its clean capture locally; nothing leaves the Mac except into the user's Claude Code session |
| D5 | Push each sketch into Claude Code once, in order, and never lose one if Claude Code is not running |
| D6 | Accept one reply per sketch from Claude Code and show it on the iPad |
| D7 | Show session state honestly: no session, this app's session, or a session it did not start |
| D8 | Log every request, push, reply, and state change as the user's audit trail |
| D9 | On the mirror surface, on Draw Mode entry, keep the exact frame the iPad froze, in clean pre-encode pixels, as the base for the sketch |
| D10 | Tag each sketch with the iPad that sent it |

**iPad**

| ID | Requirement |
|---|---|
| C1 | Live mirror (OpenDisplay). The iPad's other surface, the blank canvas, is in `PRD-BlankCanvas.md` |
| C2 | Finger pinch-zoom and pan, view-only. It works in Draw Mode too (2026-10-09): there two fingers always zoom and pan, one finger or the Pencil draws, and every stroke stays on the part of the frame it was drawn on |
| M1 | On the mirror surface, entering Draw Mode freezes the frame and pauses sync at once |
| M2 | Pen, eraser, undo, redo, five ink colours (redo added 2026-10-13) |
| M3 | In Draw Mode nothing is forwarded to the Mac |
| M4 | Optional text note |
| M5 | Send sends immediately and resumes sync. A mirror round is always the whole frame with the sketch over it, whatever the zoom (2026-10-09) |
| M6 | A way to leave Draw Mode without sending: Cancel keeps the strokes for the next entry, the panel's trash throws them away |
| M7 | If the Mac reports no frame for the freeze, leave Draw Mode with a message and keep the strokes |
| M8 | When a round reaches an outcome (applied, failed, or needs input) the iPad announces it in a notification, with a PR link when present. An applied round's notification leaves on its own; the others stay until dismissed. There is no list of rounds (2026-10-13): the record of a session is the Claude Code session |
| P1 | The project pill names the Claude Code session the next sketch goes to, and says when there is none or one must be picked; tapping it lists every connected session with its state. The iPad-to-Mac hop has no indicator of its own: while it is down, a waiting screen fills the iPad (2026-10-13) |
| P2 | "Connection details…" at the end of the session list opens the connection parameters, errors and the connection log |
| P3 | Entry to Draw Mode from the panel, disabled while there is no Claude Code session to send to |
| P4 | The panel can be moved to any screen edge, by dragging it or from the menu a long press opens, and stays there across modes and launches. Its grabber shows only while it is being dragged, on the side that faces its edge (2026-10-13) |

## 8. What is reused and what is new

| | Reused | New for Design Canvas |
|---|---|---|
| From OpenDisplay | Main-display mirroring over USB and WiFi, pairing, discovery, cursor (OpenDisplay's extended virtual display is not used) | Freeze frame, view-only region zoom, local drawing mode, five small control messages |
| From ai.cst.2 | Menu-bar app, local service, Claude Code Channel push, PencilKit drawing, sketch store, project setup | Clean capture at Draw Mode entry, reply from Claude Code, one pairing instead of two |

Dropped from ai.cst.2: on-demand hotkey capture, the browser extension, the iPad queue view, the separate 6-digit pairing.

Design Canvas ships as its own Mac app and iPad app, built on OpenDisplay's code rather than as a mode inside OpenDisplay, and stays GPL-3.0 like OpenDisplay. Input forwarding is dropped entirely, so the Mac app needs only the Screen Recording permission.

## 9. Open questions

Numbering is shared with the technical doc. Decided items live there.

Decided since v0.5: **G1, what is mirrored** (owner, 2026-09-17, after the first hardware sessions). The iPad mirrors the Mac's main display, whatever is in front; the extra virtual display OpenDisplay defaults to is not offered, not even as an option. Details and consequences are in the technical doc, section 1.

Decided since v0.9: **G18, visual design** (owner, 2026-10-13). The iPad follows Apple Freeform: light glass capsules over the canvas, one floating panel, a project pill. The design system, its tokens and every screen are in the Figma file named under Sources. The colour tokens meet WCAG 2.2 AA contrast on the light surfaces: text uses darker versions of the system orange, red, blue and green, and secondary text is the secondary label at 78%.

Decided since v0.8: **zoom in Draw Mode** (owner, 2026-10-09, after device testing, where a designer in Draw Mode could not zoom in to place a stroke). Zoom is no longer locked while drawing. Two fingers always zoom and pan; one finger or the Pencil draws. A mirror round is always the whole frame with the sketch over it, so zooming in, before or during Draw Mode, no longer crops what is sent. Consequences are in the technical doc, section 3, and under G13 below.

- **G5. Queued rounds.** Without Stack, should the iPad at least show a count of rounds waiting for Claude Code?
- **G6. Draw Mode edges.** Mostly settled in the technical spec's state machine: cancel keeps strokes, Send is disabled with no strokes, rotation and disconnect keep strokes for resend. Redo is in the panel since 2026-10-13. Still open: clear-all.
- **G9. Preview refresh.** The loop assumes the dev server hot-reloads. With no input forwarding, a preview that needs a manual reload means walking to the Mac.
- **G11. Note entry.** The keyboard covers the canvas. Consider a compact field or entering the note after the sketch.
- **G12. Tool set.** Arrows, rectangles, and text labels are common in design review and not in the MVP list.
- **G13. Redaction.** Screenshots of unreleased work go into the agent session. Decide whether a per-project redaction toggle is needed. Since G1 this matters more: the whole main display is streamed to the iPad, and a round captures the entire screen, not only a preview placed on a separate display. Since 2026-10-09 that is every mirror round: zooming in no longer crops what is sent, so the zoom is not a way to keep something out of a round. A round drawn on the blank canvas surface (2026-10-03) carries no screen content, though the screen is still streamed to the iPad underneath it (`PRD-BlankCanvas.md`, BG1).
- **G19. Permission prompts.** Claude Code asks for approval in the terminal. From the iPad that looks like a hang. The MVP mitigation is to keep the terminal visible on the mirrored screen, which since G1 is the Mac's main display, where the terminal opens anyway; the real fix is in future versions.
- **G22. Session limits.** Relaunching the menu-bar app orphans a running session; manually started Claude Code sessions are unsupported. Acceptable for alpha, must be documented.

## 10. Future versions

Not phased. Roughly in the order they are likely to matter.

- **Permission prompts on the iPad.** Claude Code Channels defines a permission relay; forward each prompt to the iPad as an allow-or-deny card. Integration work, not research.
- **Stack.** The queue view; the records already exist.
- **Re-send** a failed round from the iPad.
- **Element selection** with a property panel.
- **Arrows, shapes, text labels.**
- **Voice notes**, transcribed.
- **Marketplace listing** so the launch flag goes away.
- **Embedded agent.** Products like OpenKnowledge ship with a Claude agent inside. Design Canvas could run the agent itself, using the Claude Agent SDK on the user's Mac, as an alternative backend for users without Claude Code. It would remove the Channels constraints and put permission prompts and outcomes in our own UI, at the cost of owning diffs, undo, permissions, and billing, and of shifting from "complements your tool" to "another AI coding tool." It reverses a founding principle, so it needs an explicit decision.
- **Other agents**, if the embedded path does not cover them.
- **Cloud relay** for cross-network use.
- **Pending-round expiry** so a sketch drawn on a screen that no longer exists is not applied after a restart.
- **Image tool** so the audit log records that Claude Code looked at the sketch.

## 11. Success metrics

| Metric | Target |
|---|---|
| Send tap to sketch delivered to Claude Code | Under 1 s |
| Send tap to visible change on the iPad | Under 15 s median |
| Rounds that receive a reply | Near 100%, measured by the reply-compliance eval |
| Install to first change made without typing it | Under 5 minutes |
| Rounds applied without "needs input" | Trend up |
| Rounds per session | Trend up |
| Users disabling permission prompts for these sessions | Watch; signals the relay is overdue |
