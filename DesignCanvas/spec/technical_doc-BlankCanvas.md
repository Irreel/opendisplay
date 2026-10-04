# Design Canvas, blank canvas surface: Technical Specification

**Status:** Draft v0.2, 2026-10-04 (v0.1 was 2026-10-03). Companion to `PRD-BlankCanvas.md` v0.2. Requirement IDs (B) and gap numbers (BG) are shared with that PRD.
**Extends:** `technical_doc.md` v0.4. That document owns the architecture, the store, the channel, and the mirror round. This one specifies only what the blank surface adds. The wire fields are normative in `PROTOCOL.md` section 11 and are described here, not redefined.

## 1. Shape of the change

A mirror round's base image is a frame the Mac froze. A blank round's base image is a white page the Mac makes on demand. Everything downstream of the base image (compositing, the store, the claim, the channel push, the reply, the rounds list) is the existing pipeline.

```
iPad                                          Mac
surface = Blank (local choice, B1)
Draw ── no freeze, no wait (B4)
Done ── annotation {sketch, viewport,  ─────▶ CanvasSession.handleAnnotation
        zoomRect: full, base: "blank"}          base == blank:
                                                  white page at viewport pixels
                                                  (no ring, no held capture)
                                                UploadPipeline (unchanged)
                                                  POST /v1/captures   (the white page)
                                                  POST /v1/annotations {…, base: "blank"}
                                                channel: "freehand sketch on a blank page"
```

What does not change: `CaptureMode` (still fixed at `.mirror`), the sender (`Mac/MacSender.swift`), the menu-bar app, the frame ring, and the mirror round.

## 2. Wire

Two additive fields, no `pv` bump. See `PROTOCOL.md` 11.2 and 11.3.

| Field | Direction | Meaning |
|---|---|---|
| `annotation.base` | iPad to Mac | `"blank"`: composite on a white page. Absent: composite on the frozen frame, as before. A blank annotation is not preceded by `freeze` |
| `ping.blank` | Mac to iPad | `"1"`: this Mac accepts `base: "blank"`. Absent: it does not |

**Why a capability (B3).** There is no ack for `annotation` (plan ruling 5): the iPad treats a completed socket write as sent. A Mac that predates this feature would drop a blank annotation for want of a freeze capture, and the iPad would show a round that never appears. The iPad therefore offers the Blank surface only while the connected Mac's `ping` carries `blank`. The field rides `ping` and not `welcome` because `ping`'s extra fields are already the canvas engine's to set (`SenderCanvasDelegate.canvasPingFields`), and `welcome` is built inside the shared sender, which this feature does not touch.

| iPad | Mac | Result |
|---|---|---|
| new | new | Blank offered |
| new | old | No `ping.blank`; the iPad stays on Mirror |
| old | new | The iPad never sends `base`; `ping.blank` is ignored |

## 3. iPad

**Surface (B1, B3).** `CanvasSurface` (`mirror`, `blank`) in `DesignCanvas/Shared/CanvasMessages.swift`. `CanvasModel` holds the designer's `preferredSurface` and the Mac's `macSupportsBlank`; the surface actually shown is Blank only when the preference is Blank, a Mac is connected, and it supports it. The preference is persisted by the screen (`@AppStorage`); the capability arrives through `CanvasReceiverState.handlePing` and is cleared on a new connection and on a link drop.

**Draw Mode (B4, B5).** One new event on `DrawModeStateMachine`, `enterBlankDrawMode`: `LIVE → DRAWING` with no effects. No `pauseSync`, no `sendFreeze`, no deadline, so FREEZING is never entered. Every later transition is the existing machine, which is what keeps B5 true by construction: Done, Cancel, Discard, SENDING, RETRY and the resend after `hello` are the same code. The exits still emit `resumeSync`, which is a no-op when nothing was frozen.

`CanvasModel.enterDrawMode` on the Blank surface does not require a displayed frame, and records the entry as `base: blank` with a full zoom rect. `done` stamps that into the pending annotation, so the bytes resent after a link loss are identical to the first attempt.

**Screen.** On the Blank surface the mirror layer shows a white page that fills the view, in place of the video (or of the waiting screen, when connected with no picture yet). The sketch surface and the reported `viewport` both use that same rect, so the sketch and the page the Mac builds have one aspect. Zoom does not apply to the page.

**Switching (B6, B9).** `CanvasModel.chooseSurface(_:pageViewport:)` records the choice and, when it is Blank and the page can be shown, enters Draw Mode at once. It is called only from the control below, so nothing but the designer's tap opens Draw Mode. A two-segment control in the status panel. The panel is not shown in Draw Mode, and the control is disabled outside LIVE, so the surface cannot change under a sketch.

## 4. Mac engine

`CanvasSession.handleAnnotation`, when `base == blank`:

1. The `t` dedupe runs first, unchanged, so a resent blank annotation is dropped exactly like a resent mirror one.
2. The page size is `CanvasSession.blankPageSize(for:)`: `viewport.w × scale` by `viewport.h × scale` pixels, each side clamped to 4096. A viewport with a non-positive side or scale is dropped with a log line. Only the size is decided on the sender's queue; the page itself (`Compositor.blankImage(width:height:)`, opaque white, sRGB) is allocated by `UploadPipeline` on its work queue, as `AnnotationJob.base = .blank(width:height:)`, so the sender's queue still does no image work.
3. The held freeze capture and the parking lot's parked capture are neither read nor consumed. A mirror freeze that is still waiting for its own annotation is unaffected.
4. The job goes to `UploadPipeline` as usual. No separate capture job is queued: `runAnnotation` already posts the capture when the job's has no id.

The page's `capturedAt` is the moment the annotation arrived, since there is no frame time. `CanvasStatus.pingFields` always carries `blank`.

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
- `CanvasReceiverStateTests`: `ping.blank` sets the capability; an absent field clears it; a new connection resets it.
- `CanvasModelTests`: no `freeze` is sent; no frame is required; the annotation carries `base: blank` and a full zoom rect; the resend is identical; without the capability the surface is Mirror.
- `CompositorTests`: `blankImage` size and colour.
- `CanvasSessionTests`: a blank annotation with no freeze uploads a white capture of the viewport's pixel size and the annotation with `base`; a resend is deduplicated; a held mirror capture survives a blank round.
- `DaemonClientTests`: the meta part carries `base` only for a blank upload.
- Server: instruction text for both bases; upload validation of `base`; the store persists it.

## 8. Decisions and open technical questions

**Decided (owner, 2026-10-03).** Drawing is on the iPad. The page clears on send. The iPad renders the page; the Mac streams nothing new and its sender is untouched. The surface is chosen on the iPad and the Mac app has no UI for it.

**Open.**

- **BG1.** The mirror stream runs under the page. Stopping it means a second frame source or a stop/start path inside `MacSender`, which is shared with OpenDisplay.
- **Page size cap.** 4096 px per side is above any current iPad's panel; the composite is scaled to 1568 px on the long side regardless.
