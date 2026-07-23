import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowCaptureSession {
    private let target: WindowCaptureTarget
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

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

        self.target = target
        filter = SCContentFilter(desktopIndependentWindow: window)
        configuration = SCStreamConfiguration()
        let scale = CGFloat(max(1, filter.pointPixelScale))
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.capturesAudio = false
    }

    func capture() async throws -> CGImage {
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
