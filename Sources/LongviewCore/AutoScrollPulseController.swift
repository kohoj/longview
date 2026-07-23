import CoreGraphics
import Foundation

public enum AutoScrollPulseControllerError: Error, Equatable, Sendable {
    case targetLeaseInvalid
}

/// Validates the foreground target lease immediately before emitting one
/// bounded wheel pulse. There is no queue, inertia, retry, or delayed follow-up.
@MainActor
public struct AutoScrollPulseController {
    private let eventPoster: any ScrollEventPosting
    private let leaseValidator: any ScrollTargetLeaseValidating

    public init(
        eventPoster: any ScrollEventPosting = SystemScrollEventPoster(),
        leaseValidator: any ScrollTargetLeaseValidating = SystemScrollTargetLeaseValidator()
    ) {
        self.eventPoster = eventPoster
        self.leaseValidator = leaseValidator
    }

    public func postPulse(
        target: AutoScrollTarget,
        direction: AutoScrollDirection,
        speed: AutoScrollSpeed
    ) throws {
        guard leaseValidator.isValid(target) else {
            throw AutoScrollPulseControllerError.targetLeaseInvalid
        }
        let magnitude = speed.pixelsPerPulse
        let delta = direction == .up ? magnitude : -magnitude
        try eventPoster.postPixelDelta(delta)
    }
}
