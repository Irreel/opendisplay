// The Mac's main display, captured once for every iPad that mirrors it.
//
// One ScreenCaptureKit stream however many iPads are connected: they all show
// the same screen, so a stream per device would capture (and ring) the same
// pixels several times over. It runs only while at least one iPad is
// streaming, so the screen is never recorded with nobody watching.
//
// All state is confined to the stream queue, which is also where frames are
// delivered.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// One captured frame. `number` is unique for the app's life and increases
/// with every frame, across capture restarts too.
struct CapturedFrame {
    let number: UInt64
    let pixelBuffer: CVPixelBuffer
    let capturedAt: Date

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// `@unchecked Sendable`: every mutable field is confined to `queue`.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case waitingForPermission
        case starting
        case running(width: Int, height: Int)
        case failed(String)
    }

    /// Every new frame, on the stream queue.
    var onFrame: ((CapturedFrame) -> Void)?
    /// The user stopped sharing from the system's recording indicator.
    var onStoppedByUser: (() -> Void)?
    var onStateChange: ((State) -> Void)?

    /// The last frame delivered. ScreenCaptureKit sends nothing while the
    /// screen does not change, so this is what a keyframe for a new or
    /// resyncing iPad is made from. Holding it costs one buffer of the pool.
    private(set) var latest: CapturedFrame?
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let queue: DispatchQueue
    private let status: CanvasStatus
    private var wanted = false
    private var stream: SCStream?
    /// Bumped on every start and stop, so an asynchronous start that lost the
    /// race to a stop (or to a newer start) never installs its stream.
    private var generation = 0
    private var nextNumber: UInt64 = 1
    private var recoveryFailures = 0
    private var reconfigurationRegistered = false
    private var restartPending = false

    init(queue: DispatchQueue, status: CanvasStatus) {
        self.queue = queue
        self.status = status
        super.init()
    }

    deinit {
        if reconfigurationRegistered {
            CGDisplayRemoveReconfigurationCallback(ScreenCapture.reconfigured,
                                                   Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// On the stream queue. Starting is asynchronous; stopping is immediate.
    func setWanted(_ wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        if wanted {
            registerForReconfiguration()
            recoveryFailures = 0
            start()
        } else {
            stop()
            state = .stopped
        }
    }

    // MARK: - Start and stop

    private func start() {
        generation += 1
        let attempt = generation
        state = .starting
        Task { [weak self] in
            await self?.startCapture(attempt: attempt)
        }
    }

    private func stop() {
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
        latest = nil
    }

    private func startCapture(attempt: Int) async {
        // Polled off the main actor: on macOS 26 the main-actor answer was
        // seen to say no while capture itself was allowed.
        guard CGPreflightScreenCaptureAccess() else {
            queue.async { [weak self] in
                guard let self, self.generation == attempt, self.wanted else { return }
                if self.state != .waitingForPermission {
                    Log.info("capture: Screen Recording not granted — waiting for it")
                }
                self.state = .waitingForPermission
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.generation == attempt, self.wanted else { return }
                    self.start()
                }
            }
            return
        }
        do {
            let content = try await SCShareableContent.current
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                    ?? content.displays.first else {
                throw CaptureError.noDisplay
            }
            // SCDisplay's size is in points; the active mode knows the pixels.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let size = StreamGeometry.streamSize(pixelWidth: mode?.pixelWidth ?? display.width,
                                                 pixelHeight: mode?.pixelHeight ?? display.height,
                                                 scale: StreamQuality.stored.scale)
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            // The encoder's native input, so VideoToolbox does no conversion.
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // One buffer is held as `latest`, one or two sit in encoders.
            config.queueDepth = 6
            config.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            queue.async { [weak self] in
                guard let self, self.generation == attempt, self.wanted else {
                    stream.stopCapture { _ in }
                    return
                }
                self.stream = stream
                self.recoveryFailures = 0
                self.state = .running(width: size.width, height: size.height)
                Log.info("capture: started \(size.width)x\(size.height) of display \(display.displayID) quality=\(StreamQuality.stored.rawValue)")
            }
        } catch {
            queue.async { [weak self] in
                guard let self, self.generation == attempt, self.wanted else { return }
                Log.info("capture: start failed (\(error.localizedDescription))")
                self.state = .failed(error.localizedDescription)
                self.scheduleRecovery()
            }
        }
    }

    /// A capture that died or would not start is retried: quickly at first,
    /// then every 30 s. A lock or a display sleep takes the screen away for as
    /// long as the user is gone, and it always comes back.
    private func scheduleRecovery() {
        recoveryFailures += 1
        let delay: TimeInterval = recoveryFailures <= 5 ? 3 : 30
        let attempt = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == attempt, self.wanted, self.stream == nil else { return }
            self.start()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === self.stream, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let frame = CapturedFrame(number: nextNumber, pixelBuffer: pixelBuffer, capturedAt: now)
        nextNumber += 1
        latest = frame
        status.noteFrame(at: now)
        onFrame?(frame)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, stream === self.stream else { return }
            Log.info("capture: stream stopped (\(error.localizedDescription))")
            self.stream = nil
            self.latest = nil
            // A stop from the menu-bar recording indicator is the user's
            // decision. ScreenCaptureKit also reports `.userStopped` when the
            // console goes away (lock, fast user switch), which is not.
            if let scError = error as? SCStreamError, scError.code == .userStopped,
               Self.consoleIsInteractive {
                self.state = .stopped
                self.onStoppedByUser?()
                return
            }
            self.state = .failed(error.localizedDescription)
            self.scheduleRecovery()
        }
    }

    private static var consoleIsInteractive: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }

    // MARK: - Display changes

    /// A resolution change, a new main display or a monitor plugged in all
    /// change what should be captured, so a running capture restarts.
    private func registerForReconfiguration() {
        guard !reconfigurationRegistered else { return }
        reconfigurationRegistered = true
        CGDisplayRegisterReconfigurationCallback(ScreenCapture.reconfigured,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag) else { return }
        let capture = Unmanaged<ScreenCapture>.fromOpaque(context).takeUnretainedValue()
        capture.queue.async { capture.displaysChanged() }
    }

    private func displaysChanged() {
        guard wanted, !restartPending else { return }
        restartPending = true
        // One change arrives as a burst of callbacks; restart once it settles.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.wanted else { return }
            Log.info("capture: displays changed — restarting the capture")
            self.stop()
            self.start()
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "macOS reported no display to capture" }
    }
}
