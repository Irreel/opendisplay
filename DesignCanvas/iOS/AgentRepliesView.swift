// What Claude Code did with each sketch (M8). The Mac sends a snapshot of the
// last 20 rounds after every `hello` and an `agentReply` for each live status
// change, so this list is never polled and never stale for long.

import SwiftUI

struct AgentRepliesView: View {

    @ObservedObject var model: CanvasModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.rounds.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No rounds yet")
                            .font(.headline)
                        Text("Sketches you send appear here with what Claude Code did about them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.rounds, id: \.annotationId) { round in
                        RoundRow(round: round)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Agent replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RoundRow: View {
    let round: CanvasRound

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(status: round.status)

            if let note = round.note, !note.isEmpty {
                Text(note)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = round.message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // http(s) only: the link's text comes from the model (M4).
            if let url = round.openablePRURL {
                Link(destination: url) {
                    Label("Open pull request", systemImage: "arrow.up.forward.square")
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// `queued`, `sent`, `applied`, `failed`, `needs input` — the five round
/// statuses, spelled for a person.
struct StatusBadge: View {
    let status: RoundStatus

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Status: \(title)")
    }

    private var title: String {
        switch status {
        case .queued: return "queued"
        case .sent: return "sent"
        case .applied: return "applied"
        case .failed: return "failed"
        case .needsInput: return "needs input"
        }
    }

    private var tint: Color {
        switch status {
        case .queued: return .secondary
        case .sent: return .blue
        case .applied: return .green
        case .failed: return .red
        case .needsInput: return .orange
        }
    }
}
