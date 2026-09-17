import SwiftUI
import Combine
import Sparkle

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle's standard updater. `startingUpdater: true` boots the updater
    // immediately so scheduled background checks (SUEnableAutomaticChecks)
    // run; the menu item drives manual "Check for Updates…". Held for the
    // app's lifetime here so every window (menu bar + control window) shares
    // one updater instance.
    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// OpenDisplay's own wiring for the shared controller: forward input through
/// the Accessibility injector, run no canvas engine, and open the control
/// window whenever the app leaves menu-bar presentation. It lives here rather
/// than beside the controller because of what it names — `InputInjector` and
/// `MainWindow` are exactly the two things `Mac/SenderController.swift` must
/// not know about.
extension SenderControllerConfig {
    static var openDisplay: SenderControllerConfig {
        var config = SenderControllerConfig()
        // OpenDisplay forwards input: hand the sender the injector for
        // whatever display it ends up with.
        config.inputSinkFactory = { InputInjector(displayID: $0) }
        config.onPresentationChanged = { presentation in
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
        return config
    }
}

extension SenderController {
    static let shared = SenderController(config: .openDisplay)
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads, iPhones and Macs as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button("Disconnect All") { controller.disconnectAll() }
                        .controlSize(.large)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Section("Devices") {
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = entry.preferredTarget {
                                    Button("Connect") {
                                        controller.connect(to: target, userInitiated: true)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Picker("Mode", selection: $controller.mode) {
                    Text("Extend").tag(CaptureMode.extend)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.mode) { controller.restartAll() }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 540)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(session.transportLabel) · \(session.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if session.mbps > 0 {
                Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                if session.failed {
                    controller.retry(session)
                } else {
                    session.sender.forceReconnect()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(session.failed
                ? "Start this connection over"
                : "Drop the connection and pair with the device again")
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}

