import CoreGraphics
import Foundation
import LongviewCapture
import LongviewCore

public struct PermissionResult: Codable, Equatable, Sendable {
    public let accessibility: Bool
    public let screenCapture: Bool
}

public struct CapabilityResult: Codable, Equatable, Sendable {
    public struct LongshotCapability: Codable, Equatable, Sendable {
        public let targetScope: String
        public let targetSelectors: [String]
        public let captureRoute: String
        public let backgroundCapture: Bool
        public let backgroundScroll: String
        public let knownProfiles: [String]
        public let defaultFocusPolicy: String
        public let focusPolicies: [String]
        public let scrollRoutes: [String]
        public let regionModes: [String]
        public let directions: [String]
        public let frameRange: [Int]
        public let pulsesPerStepRange: [Int]
        public let settleMillisecondsRange: [Int]
        public let outputFormat: String
        public let restoration: String
        public let limitations: [String]
    }

    public let cliVersion: String
    public let schemaVersion: Int
    public let commands: [String]
    public let permissions: PermissionResult
    public let mutationBoundary: [String]
    public let longshot: LongshotCapability
}

public struct TargetResult: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowNumber: UInt32?
    public let title: String?
    public let isOnScreen: Bool?
    public let windowFrame: Frame

    public init(target: AutoScrollTarget) {
        processIdentifier = target.processIdentifier
        bundleIdentifier = target.bundleIdentifier
        applicationName = target.applicationName
        windowNumber = target.windowNumber
        title = nil
        isOnScreen = nil
        windowFrame = Frame(
            x: target.windowFrame.origin.x,
            y: target.windowFrame.origin.y,
            width: target.windowFrame.width,
            height: target.windowFrame.height
        )
    }

    public init(target: WindowCaptureTarget, includeTitle: Bool = true) {
        processIdentifier = target.processIdentifier
        bundleIdentifier = target.bundleIdentifier
        applicationName = target.applicationName
        windowNumber = target.windowID
        title = includeTitle ? target.title : nil
        isOnScreen = target.isOnScreen
        windowFrame = Frame(
            x: target.frame.origin.x,
            y: target.frame.origin.y,
            width: target.frame.width,
            height: target.frame.height
        )
    }
}

public struct WindowListResult: Codable, Equatable, Sendable {
    public let windows: [TargetResult]
}

public struct ScrollResult: Codable, Equatable, Sendable {
    public let target: TargetResult
    public let direction: String
    public let speed: String
    public let emittedPulses: Int
    public let pixelsPerPulse: Int32
    public let dryRun: Bool
    public let elapsedMilliseconds: Int
}

public struct LongshotResult: Codable, Equatable, Sendable {
    public let target: TargetResult
    public let outputPath: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let capturedFrameCount: Int
    public let detectedOverlaps: [Int]
    public let captureRegion: TargetResult.Frame
    public let scrollRoute: String
    public let stopReason: String
    public let targetWasActivated: Bool
    public let pointerWasMoved: Bool
    public let viewportRestorationAttempted: Bool
    public let viewportRestorationSucceeded: Bool
    public let environmentRestorationSucceeded: Bool
}

public struct VersionResult: Codable, Equatable, Sendable {
    public let version: String
    public let schemaVersion: Int
}

public struct ScrollProgressEvent: Codable, Equatable, Sendable {
    public let phase: String
    public let emittedPulses: Int
    public let totalPulses: Int
}

public struct LongshotProgressEvent: Codable, Equatable, Sendable {
    public let phase: String
    public let route: String?
    public let current: Int?
    public let total: Int?
}
