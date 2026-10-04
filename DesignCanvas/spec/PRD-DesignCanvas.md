# PRD: Design Canvas

**Status:** Draft v0.8, 2026-10-03 (v0.7 was 2026-09-22; v0.6 was 2026-09-18, after the first hardware sessions; v0.5 was 2026-09-16, after the engineering review). v0.8 scopes the mirror requirements to the mirror surface, now that the iPad also has a blank canvas surface; that surface is specified in its own document, `PRD-BlankCanvas.md`, and nothing about it is repeated here. v0.7 added the Mac-app information architecture from the board after the second dogfooding round. v0.6 recorded the decision on G1: the iPad mirrors the Mac's own screen, and there is no extended display. Product requirements only; the technical specification is in `technical_doc.md`.
**Owner:** AntheaZ
**Sources:** [FigJam board "Design Canvas"](https://www.figma.com/board/eMxEcxvPAeNtaoWbsKaa6S/Design-Canvas?node-id=0-1); the ai.cst.2 repo (the earlier build we dogfooded and pivoted from); OpenDisplay.

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
3. One tap ("Done") sends the sketch plus optional text into the running Claude Code session. No prompt typed on the Mac.
4. Claude Code's outcome (applied, failed, needs input, PR link) shows on the iPad.
5. The fix is visible on the same iPad without leaving the app.
6. Connection health for both hops (iPad to Mac, Mac to Claude Code) is visible at a glance.
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

**Amy:** opens the Design Canvas menu-bar app, picks her project, taps Start session. A terminal opens with Claude Code attached. Her iPad, already paired from OpenDisplay, mirrors the preview. She zooms into the header, enters draw mode, circles a misaligned icon, draws an arrow, types "align with the title baseline", taps Done. Claude Code reads the sketch, edits the source, replies "applied" with a PR link. The mirror updates, Amy sees the fix and the status on her iPad, and starts the next round.

## 5. Flow

**Setup, once.** Install both apps. Pair over OpenDisplay (Bonjour or USB, no code). Pick the project in the menu-bar app. Tap Start session; the app launches Claude Code with the Design Canvas channel attached.

**Each round.**

1. The iPad mirrors the Mac.
2. Pinch to zoom into a region.
3. Enter Draw Mode. The iPad freezes on the current frame at the current zoom; the Mac captures a clean still of the same moment. If zoomed in, the sketch is sent as that cropped region.
4. Draw. Optionally type a note.
5. Tap Done. Draw Mode exits, sync resumes, the sketch is sent.
6. Claude Code receives it, edits the source, replies with a status.
7. The live mirror shows the change; the round shows its status on the iPad.

## 6. Information architecture

From the board (re-read 2026-09-22). Stack is drawn but deprioritized for the MVP. The Mac-app tree is new on the board since the second dogfooding round; the iPad tree is unchanged.

**iPad**

```
Canvas (finger gesture to zoom in and out)
Panel
 ├─ Connection Status
 │    ├─ iPad to Mac, Mac to Claude Code: working or not
 │    ├─ Project: connected project folder name, or "unselected"
 │    └─ tap ──▶ modal with connection parameters and detailed error messages
 ├─ Draw Mode
 │    ├─ Drawing tool panel: pen, eraser, undo, color
 │    ├─ Text prompt entry (optional)
 │    └─ "Done": exits Draw Mode, sends to Claude Code, resumes sync
 └─ Stack (deprioritized)
      ├─ Thumbnails of saved sketches; failed sends marked with a badge
      └─ "Done"
Agent replies (status per round: queued, sent, applied, failed, needs input, PR link)
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
| C2 | Finger pinch-zoom and pan, view-only |
| M1 | On the mirror surface, entering Draw Mode freezes the frame and pauses sync at once |
| M2 | Pen, eraser, undo, color |
| M3 | In Draw Mode nothing is forwarded to the Mac |
| M4 | Optional text note |
| M5 | Done sends immediately and resumes sync |
| M6 | A way to leave Draw Mode without sending |
| M7 | If the Mac reports no frame for the freeze, leave Draw Mode with a message and keep the strokes |
| M8 | Agent replies: each round shows queued, sent, applied, failed, or needs input, with a PR link when present |
| P1 | Connection status shows both hops and the connected project folder name, or "unselected" |
| P2 | Tapping status opens details and errors |
| P3 | Entry to Draw Mode |

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

- **G5. Queued rounds.** Without Stack, should the iPad at least show a count of rounds waiting for Claude Code?
- **G6. Draw Mode edges.** Mostly settled in the technical spec's state machine: cancel keeps strokes, Done is disabled with no strokes, rotation and disconnect keep strokes for resend. Still open: redo and clear-all in the tool panel.
- **G9. Preview refresh.** The loop assumes the dev server hot-reloads. With no input forwarding, a preview that needs a manual reload means walking to the Mac.
- **G11. Note entry.** The keyboard covers the canvas. Consider a compact field or entering the note after the sketch.
- **G12. Tool set.** Arrows, rectangles, and text labels are common in design review and not in the MVP list.
- **G13. Redaction.** Screenshots of unreleased work go into the agent session. Decide whether a per-project redaction toggle is needed. Since G1 this matters more: the whole main display is streamed to the iPad, and a round sent without zooming in captures the entire screen, not only a preview placed on a separate display. A round drawn on the blank canvas surface (2026-10-03) carries no screen content, though the screen is still streamed to the iPad underneath it (`PRD-BlankCanvas.md`, BG1).
- **G18. Visual design.** The board's "Design tokens" and "sketches" sections are empty.
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
| Done tap to sketch delivered to Claude Code | Under 1 s |
| Done tap to visible change on the iPad | Under 15 s median |
| Rounds that receive a reply | Near 100%, measured by the reply-compliance eval |
| Install to first change made without typing it | Under 5 minutes |
| Rounds applied without "needs input" | Trend up |
| Rounds per session | Trend up |
| Users disabling permission prompts for these sessions | Watch; signals the relay is overdue |
