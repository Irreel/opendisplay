// H.264 for one iPad's link: real-time, no frame reordering, a keyframe only
// when asked for one. Each link has its own, so a slow WiFi iPad never holds
// back a cabled one, and backpressure stays per link.
//
// The settings are OpenDisplay's (Mac/MacSender.swift), which were measured
// on hardware; the output is handed over exactly as VideoToolbox emits it.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoEncoder {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?

    /// Nil when VideoToolbox will not start an encoder of this size.
    init?(width: Int, height: Int, bitrate: Int) {
        self.width = width
        self.height = height
        // Low-latency rate control needs an encoder that offers it; Macs whose
        // only encoder is AMD have none, so fall back to the default one.
        if let created = Self.makeSession(width: width, height: height, lowLatency: true) {
            session = created
        } else if let created = Self.makeSession(width: width, height: height, lowLatency: false) {
            Log.info("encoder: low-latency rate control unavailable — using the default encoder")
            session = created
        } else {
            Log.info("encoder: VideoToolbox could not create a \(width)x\(height) H.264 session")
            return nil
        }
        guard let session else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic keyframes: each is a bitrate spike, TCP loses nothing,
        // and the link asks for one whenever a decoder needs it.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.info("encoder: ready \(width)x\(height) at \(bitrate / 1_000_000) Mbps")
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// Encodes one frame. The completion runs on a VideoToolbox thread with
    /// the packet, or nil when the frame was rejected. Returns false when the
    /// frame could not even be submitted (the completion then never runs).
    func encode(_ frame: CapturedFrame, forceKeyframe: Bool,
                completion: @escaping (VideoPacket?, OSStatus) -> Void) -> Bool {
        guard let session else { return false }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil
        let number = frame.number
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else {
                completion(nil, status)
                return
            }
            completion(Self.packet(from: sample, frame: number), status)
        }
        return status == noErr
    }

    // MARK: - Packaging

    static func packet(from sample: CMSampleBuffer, frame: UInt64) -> VideoPacket? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let keyframe = isKeyframe(sample)
        var parameterSets: [Data] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    parameterSets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        return VideoPacket(frame: frame, isKeyframe: keyframe, parameterSets: parameterSets, sample: bytes)
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let first = (attachments as? [[CFString: Any]])?.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func makeSession(width: Int, height: Int, lowLatency: Bool) -> VTCompressionSession? {
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        return status == noErr ? session : nil
    }
}
