// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/ScreenRecordingPermission.swift`,
// unchanged. Screen Recording is the only TCC grant Design Canvas ever asks for: the sender
// captures the display, and nothing here touches Accessibility.

import AppKit
import CoreGraphics

enum ScreenRecordingPermission {
    /// True if Screen Recording is currently granted (no prompt).
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system permission prompt on first call. Returns whether granted now.
    /// macOS quirk: a freshly-granted permission often needs an app relaunch to take effect.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
