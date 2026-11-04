# Design Canvas, blank canvas surface: Technical Specification

**Status:** Draft v0.4, 2026-11-03 (v0.3 was earlier the same day; v0.2 was 2026-10-04; v0.1 was 2026-10-03). v0.4 follows Design Canvas onto its own Mac-iPad link: the blank surface needs no capability field any more (section 2), and the open question on the mirror stream no longer involves OpenDisplay (section 8). v0.3 follows the v3.1 interface: the window menu, the always-ready page and the question before a switch with ink (B6, B9). Companion to `PRD-BlankCanvas.md` v0.3. Requirement IDs (B) and gap numbers (BG) are shared with that PRD.
**Extends:** `technical_doc.md` v0.9. That document owns the architecture, the store, the channel, and the mirror round. This one specifies only what the blank surface adds. The wire fields are normative in `wire-protocol.md` section 6 and are described here, not redefined.

## 1. Shape of the change

A mirror round's base image is a frame the Mac froze. A blank round's base image is a white page the Mac makes on demand. Everything downstream of the base image (compositing, the store, the claim, the channel push, the reply, the rounds list) is the existing pipeline.

```
iPad                                          Mac
surface = Blank (local choice, B1)
Draw ── no freeze, no wait (B4)
Done ── annotation {viewport,          ─────▶ CanvasSession.handleAnnotation
        base: "blank"} + sketch PNG             base == blank:
                                                  white page at viewport pixels
                                                  (no ring, no held capture)
                                                UploadPipeline (unchanged)
                                                  POST /v1/captures   (the white page)
                                                  POST /v1/annotations {…, base: "blank"}
                                                channel: "freehand sketch on a blank page"
```

What does not change: the capture (the main display, mirror only), the link (`Mac/Stream`), the menu-bar app, the frame ring, and the mirror round.

## 2. Wire

One field, `annotation.base` (`wire-protocol.md` section 6):

| Field | Direction | Meaning |
|---|---|---|
| `annotation.base` | iPad to Mac | `"blank"`: composite on a white page. Absent: composite on the frozen frame, as before. A blank annotation is not preceded by `freeze` |

**No capability flag (B3, since 2026-11-03).** There is no ack for `annotation` (plan ruling 5): the iPad treats a completed socket write as sent, so a Mac that could not composite a blank sketch would leave the iPad showing a round that never appears. On the OpenDisplay wire the Mac therefore advertised `ping.blank` and the iPad offered the page only to a Mac that did. Both apps now speak one wire version and every Mac accepts `base: "blank"`, so the flag is gone: the page is offered whenever a Mac is connected.

## 3. iPad

**Surface (B1, B3).** `CanvasSurface` (`mirror`, `blank`) in `DesignCanvas/Shared/CanvasMessages.swift`. `CanvasModel` holds the designer's `preferredSurface`; the surface actually shown is Blank only when the preference is Blank and a Mac is connected (`whiteboardAvailable`). The preference is persisted by the screen (`@AppStorage`).

**Draw Mode (B4, B5).** One new event on `DrawModeStateMachine`, `enterBlankDrawMode`: `LIVE → DRAWING` with no effects. No `pauseSync`, no `sendFreeze`, no deadline, so FREEZING is never entered. Every later transition is the existing machine, which is what keeps B5 true by construction: Done (Send), Discard, SENDING, RETRY and the resend after `hello` are the same code. The exits still emit `resumeSync`, which is a no-op when nothing was frozen.

`CanvasModel.enterDrawMode` on the Blank surface does not require a displayed frame, and records the entry as `base: blank`. `done` stamps that into the pending annotation, so the bytes resent after a link loss are identical to the first attempt.

**Screen.** On the Blank surface the mirror layer shows a white page that fills the view, in place of the video (or of the waiting screen, when connected with no picture yet). The sketch surface and the reported `viewport` both use that same rect, so the sketch and the page the Mac builds have one aspect. Zoom does not apply to the page.

**Switching (B6, B9).** The window menu (`WindowSwitcher.swift`) picks the surface; it is disabled while a round is freezing, being sent or kept to resend. A pick with ink on the page asks "End without sending?" first; ending discards the sketch, and the choice is stored (`@AppStorage`) and passed to `CanvasModel.chooseSurface(_:pageViewport:)`. The page is always ready to draw: `CanvasScreen.keepWhiteboardReady()` runs whenever the surface or the Draw Mode state changes and enters Draw Mode when the page is up, the state is LIVE and a Design Canvas Mac is connected, so the switch, a remembered choice returning with the connection and the end of a send all open it (B9, changed 2026-11-02). There is no button to start or end drawing on the page.

## 4. Mac engine

`CanvasSession.handleAnnotation`, when `base == blank`:

1. The `t` dedupe runs first, unchanged, so a resent blank annotation is dropped exactly like a resent mirror one.
2. The page size is `CanvasSession.blankPageSize(for:)`: `viewport.w × scale` by `viewport.h × scale` pixels, each side clamped to 4096. A viewport with a non-positive side or scale is dropped with a log line. Only the size is decided on the sender's queue; the page itself (`Compositor.blankImage(width:height:)`, opaque white, sRGB) is allocated by `UploadPipeline` on its work queue, as `AnnotationJob.base = .blank(width:height:)`, so the sender's queue still does no image work.
3. The session's held freeze capture is neither read nor consumed. A mirror freeze that is still waiting for its own annotation is unaffected.
4. The job goes to `UploadPipeline` as usual. No separate capture job is queued: `runAnnotation` already posts the capture when the job's has no id.

The page's `capturedAt` is the moment the annotation arrived, since there is no frame time.

`AnnotationUpload` gains `base`; the multipart `meta` part carries `"base": "blank"` for a blank round and omits the key otherwise.

## 5. Daemon and channel (B7, B8)

- `AnnotationMeta.base?: 'blank'`, validated on upload (absent or `"blank"`; anything else is `400 invalid_request`) and persisted in the record. A record without it is a mirror round, so the store needs no migration.
- The white page is stored as the round's capture like any other, which keeps the "every annotation has a source capture" invariant and the capture sweep unchanged.
- Notification content for a blank round:

```
New sketch from iPad (blank canvas).
Annotation ID: <uuid v7>
Device: <iPad name>
Sent at: <iso>
Composite PNG path: <absolute path>
Note: <text or "(none)">

This is a freehand sketch drawn on a blank page, not a screenshot of the running app.
Inspect the composite PNG path to see it, read it together with the note, and act on it in this project, then call design_canvas_reply with the outcome.
```

"Captured at" and "Zoom region" are omitted: neither means anything without a frame. `meta` is unchanged. The server `instructions` gain one sentence saying a round may be a blank-page sketch.

## 6. Failure modes

| Case | Behaviour |
|---|---|
| Link drops between Done and the write | RETRY; identical annotation resent after `hello`. No parked capture is needed, so unlike a mirror round this survives a Mac app restart |
| Mac lost the capability (reconnect to an older Mac) with Blank preferred | The iPad shows Mirror; the preference is kept for the next capable Mac |
| A sketch stranded in RETRY reconnects to an older Mac | Resent with `base: blank` and dropped there. Same exposure as any unacked annotation (TODOS.md, `annotationAck`) |
| Rotation while drawing on the page | Draw Mode ends, strokes kept, as on the mirror surface (the viewport changed) |
| Daemon down | Queued in `UploadPipeline` and retried, as for a mirror round |

## 7. Tests

All hostless.

- `CanvasMessagesTests`: `base` round-trips; absent or unknown decodes as mirror; a mirror annotation's JSON has no `base` key.
- `DrawModeStateMachineTests`: blank entry reaches DRAWING with no effects; Done, Cancel, Discard and link loss behave as from a frozen DRAWING.
- `CanvasModelTests`: no `freeze` is sent; no frame is required; the annotation carries `base: blank` and the sketch as its attachment; the resend is identical; with no Mac connected the surface is Mirror.
- `CompositorTests`: `blankImage` size and colour.
- `CanvasSessionTests`: a blank annotation with no freeze uploads a white capture of the viewport's pixel size and the annotation with `base`; a resend is deduplicated; a held mirror capture survives a blank round.
- `DaemonClientTests`: the meta part carries `base` only for a blank upload.
- Server: instruction text for both bases; upload validation of `base`; the store persists it.

## 8. Decisions and open technical questions

**Decided (owner, 2026-10-03).** Drawing is on the iPad. The page clears on send. The iPad renders the page; the Mac streams nothing new and its capture is untouched. The surface is chosen on the iPad and the Mac app has no UI for it.

**Open.**

- **BG1.** The mirror stream runs under the page. The capture already starts and stops with the iPads that watch it (`ScreenCapture.setWanted`), so stopping it under the page is a matter of the iPad saying the page is up; it is not built.
- **Page size cap.** 4096 px per side is above any current iPad's panel; the composite is scaled to 1568 px on the long side regardless.
