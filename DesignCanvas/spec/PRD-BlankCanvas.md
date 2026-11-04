# PRD: Design Canvas, blank canvas surface

**Status:** Draft v0.3, 2026-11-03 (v0.2 was 2026-10-04; v0.1 was 2026-10-03). v0.3 follows the v3.1 interface (owner, 2026-11-02): the surface is picked in the window menu, the whiteboard is always ready to draw (B9 changed), picking the other surface with ink on the page asks first and gives the sketch up (B6 changed, BG3 decided), and Done is Send. v0.2 added B9: switching to Blank opens Draw Mode. Product requirements only; the technical specification is in `technical_doc-BlankCanvas.md`.
**Owner:** AntheaZ
**Extends:** `PRD-DesignCanvas.md` v0.8. That document owns the mirror loop and everything the two surfaces share (pairing, the session, the drawing tools, replies). This one owns only what the blank surface adds or changes. Where a requirement here depends on one there, it is cited by ID and not restated.

## 1. One-liner

Besides the live mirror of the Mac, the iPad offers a blank page. The designer sketches an idea on it freehand, and the sketch goes into the same running Claude Code session as any other round.

## 2. Problem

Every round in Design Canvas starts from a frame of the running feature, which fits review feedback: "this is wrong, here." It does not fit the step before that, when there is nothing on screen to point at yet: a layout to try, a flow to rough out, a component that does not exist. Today the designer has to find something to mirror and draw over it, and the screenshot underneath then misleads the agent about what the sketch refers to.

## 3. Goals and non-goals

**Goals**

1. A blank page on the iPad, reachable in one tap, with the same drawing tools and the same Send as a mirror round.
2. The sketch reaches Claude Code as a round like any other, and Claude Code is told it is a freehand sketch and not a marked-up screenshot.
3. Nothing changes on the Mac that the user has to learn: no new menu item, setting, or mode.

**Non-goals**

- Drawing on the Mac itself.
- A persistent whiteboard, multiple pages, or a saved history of pages. Each round is a fresh page.
- Stopping the screen stream while the blank page is up (section 6, BG1).
- Any change to what a mirror round does.

## 4. Flow

1. On the iPad, tap the window button under the session pill and pick Whiteboard. The mirror is replaced by a white page.
2. The page is ready to draw at once (2026-11-02): there is no freeze, no wait and no button to tap.
3. Draw. Optionally type a note.
4. Tap Send. The sketch is sent and the page is cleared, ready for the next one.
5. Claude Code receives it, acts on it, and replies with a status, shown on the iPad as for any round.
6. Pick the Mac in the window menu to watch the result on the running feature. With ink on the page it asks first, since the sketch is not kept.

## 5. Requirements

IDs use their own prefix (B) so they cannot collide with the main PRD's D, C, M and P.

| ID | Requirement |
|---|---|
| B1 | The iPad offers two surfaces, Mirror and Blank, and the designer chooses between them on the iPad, in the window menu, where they read as the Mac's own name and Whiteboard. The choice is remembered across launches |
| B2 | The Mac app has no control, setting, or indicator for the surface. Its UI is unchanged |
| B3 | The Blank surface is offered only while the connected Mac can accept a blank sketch. With an older Mac app, or with no Mac connected, the iPad shows Mirror; with an older Mac app the window menu shows Whiteboard greyed out, saying it needs a newer Design Canvas on the Mac |
| B9 | The Blank surface is always ready to draw (changed 2026-11-02; added 2026-10-04 as: only the designer's own switch entered Draw Mode). Whenever the page is up and no round is on its way, Draw Mode is entered by itself: on the switch, when a remembered Blank choice returns with the connection, and after a sketch is sent. The page has no button to start or end drawing |
| B4 | On the Blank surface, entering Draw Mode needs no frame from the Mac and does not wait on it. A blank round can be drawn and sent even when no picture has arrived from the Mac |
| B5 | The drawing tools, the note and Send are the main PRD's M2, M4 and M5, unchanged, and Clear all is M6's. The page is cleared once the sketch is sent. Leaving without sending is the switch back to Mirror (B6) |
| B6 | Picking the other surface with ink on the page asks first ("End without sending?") and gives the sketch up (changed 2026-11-02; was: the surface could not change while a sketch was in progress). It cannot change while a round is being sent or kept to resend |
| B7 | The Mac composites the sketch on a white page of the iPad's own size and shape, and stores and pushes the round exactly as the main PRD's D4, D5 and D10 require. No screen content is part of a blank round |
| B8 | Claude Code is told the round is a freehand sketch on a blank page, not a screenshot of the running feature. Replies are the main PRD's D6 and M8, unchanged |

## 6. Open questions

- **BG1. The hidden stream.** While the Blank surface is up the Mac keeps capturing and streaming its screen underneath, so Screen Recording is still required and the screen still crosses the link. Stopping capture for the duration is the clean behaviour and a larger change to the sender; deferred until it matters in use.
- **BG2. What Claude Code should do with it.** A blank sketch has no element to anchor to, so its meaning rests on the note. Whether a blank round without a note should be allowed, or should prompt for one, is untested.
- **BG3. Strokes across a switch.** Decided (owner, 2026-11-02): strokes no longer cross a switch. Nothing keeps a sketch for a later entry any more, and a switch with ink on the page asks before it gives the sketch up (B6), so nothing is discarded silently.
- **BG4. Page colour and guides.** White only. A dark page, a dot grid, or device frames are not in this version.
