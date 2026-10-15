# PRD: Design Canvas, blank canvas surface

**Status:** Draft v0.2, 2026-10-04 (v0.1 was 2026-10-03). v0.2 adds B9: switching to Blank opens Draw Mode. Product requirements only; the technical specification is in `technical_doc-BlankCanvas.md`.
**Owner:** AntheaZ
**Extends:** `PRD-DesignCanvas.md` v0.8. That document owns the mirror loop and everything the two surfaces share (pairing, the session, the drawing tools, replies). This one owns only what the blank surface adds or changes. Where a requirement here depends on one there, it is cited by ID and not restated.

## 1. One-liner

Besides the live mirror of the Mac, the iPad offers a blank page. The designer sketches an idea on it freehand, and the sketch goes into the same running Claude Code session as any other round.

## 2. Problem

Every round in Design Canvas starts from a frame of the running feature, which fits review feedback: "this is wrong, here." It does not fit the step before that, when there is nothing on screen to point at yet: a layout to try, a flow to rough out, a component that does not exist. Today the designer has to find something to mirror and draw over it, and the screenshot underneath then misleads the agent about what the sketch refers to.

## 3. Goals and non-goals

**Goals**

1. A blank page on the iPad, reachable in one tap, with the same drawing tools and the same Done as a mirror round.
2. The sketch reaches Claude Code as a round like any other, and Claude Code is told it is a freehand sketch and not a marked-up screenshot.
3. Nothing changes on the Mac that the user has to learn: no new menu item, setting, or mode.

**Non-goals**

- Drawing on the Mac itself.
- A persistent whiteboard, multiple pages, or a saved history of pages. Each round is a fresh page.
- Stopping the screen stream while the blank page is up (section 6, BG1).
- Any change to what a mirror round does.

## 4. Flow

1. On the iPad, switch the surface from Mirror to Blank. The mirror is replaced by a white page.
2. Draw Mode opens by itself with that same tap (2026-10-04); there is no freeze and no wait. Leaving it with Cancel brings the panel back, where Draw re-enters and the switch returns to Mirror.
3. Draw. Optionally type a note.
4. Tap Done. The sketch is sent and the page is cleared.
5. Claude Code receives it, acts on it, and replies with a status, shown on the iPad as for any round.
6. Switch back to Mirror to watch the result on the running feature.

## 5. Requirements

IDs use their own prefix (B) so they cannot collide with the main PRD's D, C, M and P.

| ID | Requirement |
|---|---|
| B1 | The iPad offers two surfaces, Mirror and Blank, and the designer chooses between them on the iPad. The choice is remembered across launches |
| B2 | The Mac app has no control, setting, or indicator for the surface. Its UI is unchanged |
| B3 | The Blank surface is offered only while the connected Mac can accept a blank sketch. With an older Mac app, or with no Mac connected, the iPad shows Mirror |
| B9 | Switching to Blank enters Draw Mode in the same tap (added 2026-10-04). Only the designer's own switch does this: a remembered Blank choice returning with the connection, or the page coming back after a sketch is sent, leaves the panel up |
| B4 | On the Blank surface, entering Draw Mode needs no frame from the Mac and does not wait on it. A blank round can be drawn and sent even when no picture has arrived from the Mac |
| B5 | The drawing tools, the note, Done, and the ways to leave without sending are the main PRD's M2, M4, M5 and M6, unchanged. The page is cleared once the sketch is sent |
| B6 | The surface cannot change while a sketch is in progress |
| B7 | The Mac composites the sketch on a white page of the iPad's own size and shape, and stores and pushes the round exactly as the main PRD's D4, D5 and D10 require. No screen content is part of a blank round |
| B8 | Claude Code is told the round is a freehand sketch on a blank page, not a screenshot of the running feature. Replies are the main PRD's D6 and M8, unchanged |

## 6. Open questions

- **BG1. The hidden stream.** While the Blank surface is up the Mac keeps capturing and streaming its screen underneath, so Screen Recording is still required and the screen still crosses the link. Stopping capture for the duration is the clean behaviour and a larger change to the sender; deferred until it matters in use.
- **BG2. What Claude Code should do with it.** A blank sketch has no element to anchor to, so its meaning rests on the note. Whether a blank round without a note should be allowed, or should prompt for one, is untested.
- **BG3. Strokes across a switch.** A sketch kept by Cancel (M6) survives a switch between surfaces, so marks drawn over the mirror can reappear on the blank page. Kept for now because discarding a designer's strokes silently is worse; revisit after dogfooding.
- **BG4. Page colour and guides.** White only. A dark page, a dot grid, or device frames are not in this version.
