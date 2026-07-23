import CoreGraphics
import Foundation

public enum AutoScrollDirection: String, CaseIterable, Codable, Sendable {
    case up
    case down

    public var displayName: String {
        switch self {
        case .up: "向上"
        case .down: "向下"
        }
    }
}

public enum AutoScrollSpeed: String, CaseIterable, Codable, Sendable {
    case slow
    case normal
    case fast

    public var displayName: String {
        switch self {
        case .slow: "慢"
        case .normal: "正常"
        case .fast: "快"
        }
    }

    public var interval: TimeInterval {
        switch self {
        case .slow: 0.16
        case .normal: 0.10
        case .fast: 0.065
        }
    }

    public var pixelsPerPulse: Int32 {
        switch self {
        case .slow: 2
        case .normal: 4
        case .fast: 7
        }
    }
}

public struct AutoScrollConfiguration: Equatable, Sendable {
    public var direction: AutoScrollDirection
    public var speed: AutoScrollSpeed

    public init(
        direction: AutoScrollDirection = .down,
        speed: AutoScrollSpeed = .normal
    ) {
        self.direction = direction
        self.speed = speed
    }
}

public struct AutoScrollTarget: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let applicationName: String
    public let windowFrame: CGRect
    public let windowNumber: CGWindowID?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        windowFrame: CGRect,
        windowNumber: CGWindowID? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowFrame = windowFrame
        self.windowNumber = windowNumber
    }
}

public enum AutoScrollStopReason: String, Equatable, Sendable {
    case userRequested
    case emergencyShortcut
    case frontmostApplicationChanged
    case permissionMissing
    case eventPostingFailed
    case pauseLeaseExpired
}

public enum AutoScrollState: Equatable, Sendable {
    case stopped(AutoScrollStopReason?)
    case running
    case paused
}
