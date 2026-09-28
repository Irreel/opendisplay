// The one thing a Design Canvas session shows on the iPad: the Mac's screen.
//
// Owner decisions, 2026-09-17, after the first hardware sessions. PRD open
// question G1 ("what is mirrored") resolved to the screen the user is already
// looking at, and the extended display — the sender's inherited default, an
// empty extra display the preview had to be dragged onto — dropped as a
// feature rather than kept as an option.
//
// Mirroring builds no virtual display, so Design Canvas never touches macOS's
// saved per-display state, where an identity can get stuck never coming online
// (upstream #206, #221 — what made the very first hardware session show
// nothing at all).

import Foundation

extension CaptureMode {
    static let designCanvas = CaptureMode.mirror
}
