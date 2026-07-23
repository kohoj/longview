import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
public struct WindowTargetResolver {
    public init() {}

    public func list(
        bundleIdentifier: String? = nil
    ) async throws -> [WindowCaptureTarget] {
        guard CGPreflightScreenCaptureAccess() else {
            throw LongScreenshotError.screenCapturePermissionMissing
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.windows.compactMap { window in
            guard window.windowLayer == 0,
                window.frame.width >= 160,
                window.frame.height >= 120,
                let application = window.owningApplication,
                bundleIdentifier == nil || application.bundleIdentifier == bundleIdentifier
            else { return nil }
            let resolvedBundleIdentifier =
                application.bundleIdentifier.isEmpty
                ? nil
                : application.bundleIdentifier
            return WindowCaptureTarget(
                processIdentifier: application.processID,
                bundleIdentifier: resolvedBundleIdentifier,
                applicationName: application.applicationName,
                windowID: window.windowID,
                title: window.title,
                frame: window.frame,
                isOnScreen: window.isOnScreen
            )
        }.sorted {
            let lhsArea = $0.frame.width * $0.frame.height
            let rhsArea = $1.frame.width * $1.frame.height
            if lhsArea == rhsArea { return $0.windowID < $1.windowID }
            return lhsArea > rhsArea
        }
    }

    public func resolve(_ selector: WindowTargetSelector) async throws -> WindowCaptureTarget {
        let candidates = try await list(bundleIdentifier: selector.bundleIdentifier)
        if let windowID = selector.windowID {
            guard let exact = candidates.first(where: { $0.windowID == windowID }) else {
                throw LongScreenshotError.targetWindowUnavailable
            }
            return exact
        }
        guard !candidates.isEmpty else {
            throw selector.bundleIdentifier == nil
                ? LongScreenshotError.targetWindowUnavailable
                : LongScreenshotError.targetApplicationUnavailable
        }
        if let bundleIdentifier = selector.bundleIdentifier {
            let meaningful = candidates.filter {
                $0.bundleIdentifier == bundleIdentifier
                    && $0.frame.width >= 300
                    && $0.frame.height >= 300
            }
            guard let selected = meaningful.first else {
                throw LongScreenshotError.targetWindowUnavailable
            }
            return selected
        }
        guard candidates.count == 1 else {
            throw LongScreenshotError.targetWindowAmbiguous(candidates.map(\.windowID))
        }
        return candidates[0]
    }
}
