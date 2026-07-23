import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowCaptureSession {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let frameReceiver = WindowStreamFrameReceiver()
    private var stream: SCStream?
    private var stopped = false
    private var usedFallback = false

    var sourceName: String {
        usedFallback ? "screenshot-fallback" : "screen-capture-stream"
    }

    init(target: WindowCaptureTarget) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw LongScreenshotError.screenCapturePermissionMissing
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard
            let window = content.windows.first(where: {
                $0.windowID == target.windowID
                    && $0.owningApplication?.processID == target.processIdentifier
            })
        else { throw LongScreenshotError.captureWindowUnavailable }

        filter = SCContentFilter(desktopIndependentWindow: window)
        configuration = SCStreamConfiguration()
        let scale = CGFloat(max(1, filter.pointPixelScale))
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(
            frameReceiver,
            type: .screen,
            sampleHandlerQueue: frameReceiver.queue
        )
        try await stream.startCapture()
        self.stream = stream
    }

    func capture() async throws -> CGImage {
        if let frame = try await newestFrame(
            after: 0,
            maximumWaitMilliseconds: 2_000
        ) {
            return frame.image
        }
        return try await captureFallback()
    }

    func checkpoint() -> UInt64 {
        frameReceiver.snapshot()?.generation ?? 0
    }

    func captureAfterMutation(
        checkpoint: UInt64,
        maximumWaitMilliseconds: Int,
        quietWindowMilliseconds: Int = AdaptiveCapturePacer.quietFrameWindowMilliseconds
    ) async throws -> CGImage {
        guard
            var candidate = try await newestFrame(
                after: checkpoint,
                maximumWaitMilliseconds: maximumWaitMilliseconds
            )
        else {
            if let current = frameReceiver.snapshot() {
                return current.image
            }
            return try await captureFallback()
        }

        let deadline =
            DispatchTime.now().uptimeNanoseconds
            + UInt64(maximumWaitMilliseconds) * 1_000_000
        let quietWindow =
            UInt64(quietWindowMilliseconds)
            * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= candidate.receivedAt + quietWindow {
                return candidate.image
            }
            try await Task.sleep(for: .milliseconds(4))
            if let newest = frameReceiver.snapshot(),
                newest.generation > candidate.generation
            {
                candidate = newest
            }
        }
        return candidate.image
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    private func newestFrame(
        after generation: UInt64,
        maximumWaitMilliseconds: Int
    ) async throws -> WindowStreamFrameReceiver.Frame? {
        let deadline =
            DispatchTime.now().uptimeNanoseconds
            + UInt64(maximumWaitMilliseconds) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            if let frame = frameReceiver.snapshot(), frame.generation > generation {
                return frame
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        return nil
    }

    private func captureFallback() async throws -> CGImage {
        usedFallback = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard image.width > 0, image.height > 0 else {
            throw LongScreenshotError.captureWindowUnavailable
        }
        return image
    }
}

private final class WindowStreamFrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame {
        let generation: UInt64
        let image: CGImage
        let receivedAt: UInt64
    }

    let queue = DispatchQueue(
        label: "com.kohoj.longview.capture-stream",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latestFrame: Frame?
    private var latestFingerprint: UInt64?
    private var generation: UInt64 = 0

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let rawStatus = attachment[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let input = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(input, from: input.extent) else {
            return
        }
        guard let fingerprint = Self.fingerprint(image) else { return }
        lock.lock()
        if latestFingerprint == fingerprint {
            lock.unlock()
            return
        }
        generation += 1
        latestFingerprint = fingerprint
        let frame = Frame(
            generation: generation,
            image: image,
            receivedAt: DispatchTime.now().uptimeNanoseconds
        )
        latestFrame = frame
        lock.unlock()
    }

    func snapshot() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    private static func fingerprint(_ image: CGImage) -> UInt64? {
        let width = 24
        let height = 24
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .low
            let insetX = CGFloat(image.width) * 0.05
            let insetY = CGFloat(image.height) * 0.05
            guard
                let center = image.cropping(
                    to: CGRect(
                        x: insetX,
                        y: insetY,
                        width: CGFloat(image.width) - insetX * 2,
                        height: CGFloat(image.height) - insetY * 2
                    ).integral
                )
            else { return false }
            context.draw(
                center,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for component in 0..<3 {
                hash ^= UInt64(bytes[index + component] >> 3)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
}
