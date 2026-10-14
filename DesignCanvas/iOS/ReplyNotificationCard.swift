// What Claude Code did with a sketch (M8), as a card in the top-right corner
// the way a Mac shows a notification. It is this app's own view, not a system
// notification, and like the rest of the chrome it is never part of a sketch:
// Done exports the ink alone.

import SwiftUI
import UIKit

struct ReplyNotificationCard: View {

    let notification: ReplyNotification
    let onDismiss: () -> Void

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notification.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color.canvasSecondary)
                        .lineLimit(2)
                }
                if let url = notification.prURL {
                    Link(destination: url) {
                        Label("Open pull request", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.canvasAccentText)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 340)
        .canvasGlass(in: Self.shape)
        .contentShape(Self.shape)
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width > 40 || value.translation.height < -40 { onDismiss() }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses this message")
        .onAppear {
            UIAccessibility.post(notification: .announcement,
                                 argument: [title, notification.detail].compactMap { $0 }.joined(separator: ". "))
        }
        // Keyed on the card: a newer reply restarts the clock, and a card
        // that was replaced must not take its successor down with it.
        .task(id: notification.id) {
            guard !notification.staysUntilDismissed else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            onDismiss()
        }
    }

    private var title: String {
        switch notification.status {
        case .applied: return "Applied"
        case .failed: return "Couldn\u{2019}t apply"
        case .needsInput: return "Claude needs a reply at the desktop"
        case .queued, .sent: return ""
        }
    }

    private var icon: String {
        switch notification.status {
        case .applied: return "checkmark"
        case .failed: return "xmark"
        case .needsInput: return "hand.raised.fill"
        case .queued, .sent: return "paperplane"
        }
    }

    private var tint: Color {
        switch notification.status {
        case .applied: return .canvasSuccessMark
        case .failed: return .red
        case .needsInput: return .canvasWarningMark
        case .queued, .sent: return .canvasSecondary
        }
    }
}
