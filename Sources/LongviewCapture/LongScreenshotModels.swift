import CoreGraphics
import Foundation

public struct WindowCaptureTarget: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowID: CGWindowID
    public let title: String?
    public let frame: CGRect
    public let isOnScreen: Bool

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        windowID: CGWindowID,
        title: String?,
        frame: CGRect,
        isOnScreen: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

public struct WindowTargetSelector: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var windowID: CGWindowID?

    public init(
        bundleIdentifier: String? = nil,
        windowID: CGWindowID? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
    }
}

public enum LongScreenshotDirection: String, Codable, CaseIterable, Sendable {
    case up
    case down
}

public enum LongScreenshotFocusPolicy: String, Codable, CaseIterable, Sendable {
    /// Never activates the target. Only AX value changes and PID-targeted
    /// scroll events are eligible.
    case backgroundOnly = "background-only"

    /// Tries background routes first, then temporarily activates the target
    /// and restores the prior focus if public background routes have no effect.
    case backgroundFirst = "background-first"

    /// Requires the target to already be frontmost. The CLI may temporarily
    /// position and restore the pointer inside its selected scroll region.
    case foreground
}

public enum LongScreenshotRegion: Equatable, Sendable {
    case automatic
    case fullWindow
    case normalized(CGRect)
    case appProfile
}

public enum LongScreenshotScrollRoute: String, Codable, Sendable {
    case accessibilityValue = "accessibility-value"
    case pidEvent = "pid-event"
    case foregroundEvent = "foreground-event"
    case none
}

public enum LongScreenshotStopReason: String, Codable, Sendable {
    case frameLimitReached = "frame-limit-reached"
    case endReached = "end-reached"
    case singleFrame = "single-frame"
}

public struct LongScreenshotConfiguration: Equatable, Sendable {
    public var frameCount: Int
    public var pulsesPerStep: Int
    public var direction: LongScreenshotDirection
    public var focusPolicy: LongScreenshotFocusPolicy
    public var region: LongScreenshotRegion
    public var normalizedScrollPoint: CGPoint
    public var settleMilliseconds: Int
    public var stopAtEnd: Bool

    public init(
        frameCount: Int = 6,
        pulsesPerStep: Int = 28,
        direction: LongScreenshotDirection = .up,
        focusPolicy: LongScreenshotFocusPolicy = .backgroundFirst,
        region: LongScreenshotRegion = .automatic,
        normalizedScrollPoint: CGPoint = CGPoint(x: 0.65, y: 0.5),
        settleMilliseconds: Int = 450,
        stopAtEnd: Bool = true
    ) {
        self.frameCount = frameCount
        self.pulsesPerStep = pulsesPerStep
        self.direction = direction
        self.focusPolicy = focusPolicy
        self.region = region
        self.normalizedScrollPoint = normalizedScrollPoint
        self.settleMilliseconds = settleMilliseconds
        self.stopAtEnd = stopAtEnd
    }
}

public enum LongScreenshotPhase: Equatable, Sendable {
    case resolvingTarget
    case preparing
    case probingRoute(LongScreenshotScrollRoute)
    case capturing(current: Int, total: Int)
    case restoringViewport
    case restoringEnvironment
    case stitching
}

public struct LongScreenshotResult {
    public let image: CGImage
    public let target: WindowCaptureTarget
    public let capturedFrameCount: Int
    public let overlaps: [Int]
    public let regionInPixels: CGRect
    public let scrollRoute: LongScreenshotScrollRoute
    public let stopReason: LongScreenshotStopReason
    public let targetWasActivated: Bool
    public let pointerWasMoved: Bool
    public let viewportRestorationAttempted: Bool
    public let viewportRestorationSucceeded: Bool
    public let environmentRestorationSucceeded: Bool

    public init(
        image: CGImage,
        target: WindowCaptureTarget,
        capturedFrameCount: Int,
        overlaps: [Int],
        regionInPixels: CGRect,
        scrollRoute: LongScreenshotScrollRoute,
        stopReason: LongScreenshotStopReason,
        targetWasActivated: Bool,
        pointerWasMoved: Bool,
        viewportRestorationAttempted: Bool,
        viewportRestorationSucceeded: Bool,
        environmentRestorationSucceeded: Bool
    ) {
        self.image = image
        self.target = target
        self.capturedFrameCount = capturedFrameCount
        self.overlaps = overlaps
        self.regionInPixels = regionInPixels
        self.scrollRoute = scrollRoute
        self.stopReason = stopReason
        self.targetWasActivated = targetWasActivated
        self.pointerWasMoved = pointerWasMoved
        self.viewportRestorationAttempted = viewportRestorationAttempted
        self.viewportRestorationSucceeded = viewportRestorationSucceeded
        self.environmentRestorationSucceeded = environmentRestorationSucceeded
    }
}

public enum LongScreenshotError: Error, Equatable, Sendable {
    case invalidConfiguration
    case accessibilityPermissionMissing
    case screenCapturePermissionMissing
    case targetApplicationUnavailable
    case targetWindowUnavailable
    case targetWindowAmbiguous([CGWindowID])
    case targetChanged
    case foregroundRequired
    case foregroundActivationFailed
    case foregroundWindowUnavailable
    case backgroundScrollUnavailable
    case scrollRouteUnavailable
    case unsupportedApplication
    case captureWindowUnavailable
    case captureDimensionsChanged
    case cropUnavailable
    case overlapUnavailable
    case imageCompositionFailed
    case imageWriteFailed
}
