// The waiting screen's setup steps: what has to be true on the Mac before this
// iPad can mirror it. The Mac app is installed by hand. The mod is turned on by
// a prompt copied here and pasted into Claude Code there (`SetupGuide`), which
// Universal Clipboard carries across. The iPad is connected from the Mac's
// side, because the iPad only listens.

import SwiftUI
import UIKit

struct SetupGuideCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Same section header as the session list's, inset to the step numbers.
            Text("How to connect")
                .textCase(.uppercase)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.canvasSecondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            steps
        }
        .frame(maxWidth: 560)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStep(number: 1, title: "Install the Mac app") {
                Text("Download and install Design Canvas on your Mac, then open it.")
                    .stepDetail()
            }
            Divider().padding(.leading, 58)
            SetupStep(number: 2, title: "Install the Claude Code mod") {
                Text("Install it from the marketplace, or copy this prompt and paste it into Claude Code on your Mac. With Handoff on, what you copy here pastes there.")
                    .stepDetail()
                PromptBox(prompt: SetupGuide.modPrompt)
                Text("Design Canvas then loads in every Claude Code session, in every project, and starting a session opens the Mac app. The prompt does what Turn On does when the Mac app first asks, and the app\u{2019}s Settings turn it off.")
                    .font(.footnote)
                    .foregroundStyle(Color.canvasSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.leading, 58)
            SetupStep(number: 3, title: "Connect this \(deviceKind)") {
                Text("Plug this \(deviceKind) into your Mac, or, on the same WiFi, click Connect next to it in the Design Canvas menu. Mirroring starts on its own; keep this app open. Then run `claude` in your project, or click Start in that menu, and sketches go to that session.")
                    .stepDetail()
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemFill), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .accessibilityLabel("Step \(number): \(title)")
                    .accessibilityAddTraits(.isHeader)
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The prompt as it will be pasted, so the designer can read what it asks
/// Claude Code to change before copying it.
private struct PromptBox: View {
    let prompt: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt for Claude Code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.canvasSecondary)
                Spacer(minLength: 12)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(copied ? "Prompt copied" : "Copy the prompt for Claude Code")
            }
            Text(prompt)
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    private func copy() {
        UIPasteboard.general.string = prompt
        copied = true
        UIAccessibility.post(notification: .announcement, argument: "Prompt copied")
    }
}

private extension Text {
    func stepDetail() -> some View {
        font(.subheadline)
            .foregroundStyle(Color.canvasSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
