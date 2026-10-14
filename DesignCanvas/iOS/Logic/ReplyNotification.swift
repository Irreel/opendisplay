// What Claude Code did with a sketch, as the iPad announces it: one card in the
// corner of the screen when a round reaches an outcome (M8). There is no list
// behind it — the record of a session is the Claude Code session itself.
//
// Foundation only: this is compiled into the hostless test bundle.

import Foundation

struct ReplyNotification: Equatable, Identifiable {
    var annotationId: String
    var status: RoundStatus
    /// One line that tells the designer which sketch this is about, or what
    /// went wrong with it.
    var detail: String?
    /// http(s) only, like every link that came from the model (M4).
    var prURL: URL?

    var id: String { "\(annotationId)-\(status.rawValue)" }

    /// A sketch that was applied shows on the mirror too, so its card may
    /// leave on its own. One that failed or is waiting on the designer does
    /// not: missing it means waiting for something that will never come.
    var staysUntilDismissed: Bool { status != .applied }

    /// Nil for a round that has no outcome yet: `queued` and `sent` are not
    /// news.
    init?(round: CanvasRound) {
        guard round.status.progressRank == RoundStatus.applied.progressRank else { return nil }
        annotationId = round.annotationId
        status = round.status
        let note = round.note.flatMap { $0.isEmpty ? nil : $0 }
        let message = round.message.flatMap { $0.isEmpty ? nil : $0 }
        // A failure is explained by what Claude Code said; anything else is
        // best named by the designer's own note.
        detail = round.status == .failed ? (message ?? note) : (note ?? message)
        prURL = round.openablePRURL
    }
}
