import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
public protocol ScrollEventPosting {
    func postPixelDelta(_ delta: Int32) throws
}

public enum SystemScrollEventPosterError: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case eventSourceUnavailable
    case eventCreationFailed
}

/// The only input-emitting module in Longview. It can post a vertical
/// pixel-wheel event and exposes no click, keyboard, clipboard, typing, launch,
/// or application-activation primitive.
@MainActor
public struct SystemScrollEventPoster: ScrollEventPosting {
    private static let sourceTag: Int64 = 0x4846_5343_524F_4C4C

    public init() {}

    public func postPixelDelta(_ delta: Int32) throws {
        guard AXIsProcessTrusted() else {
            throw SystemScrollEventPosterError.accessibilityPermissionMissing
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SystemScrollEventPosterError.eventSourceUnavailable
        }
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
            )
        else {
            throw SystemScrollEventPosterError.eventCreationFailed
        }
        if let location = CGEvent(source: nil)?.location {
            event.location = location
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.sourceTag)
        event.post(tap: .cghidEventTap)
    }

    /// Sends one bounded pixel-wheel event directly to a process without
    /// activating it or moving the system pointer. Whether the target app
    /// honors a PID-targeted wheel event is app-specific and must be verified
    /// by the caller from observed output.
    public func postPixelDelta(
        _ delta: Int32,
        to processIdentifier: pid_t,
        at location: CGPoint
    ) throws {
        guard AXIsProcessTrusted() else {
            throw SystemScrollEventPosterError.accessibilityPermissionMissing
        }
        guard processIdentifier > 0,
            let source = CGEventSource(stateID: .hidSystemState)
        else { throw SystemScrollEventPosterError.eventSourceUnavailable }
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
            )
        else { throw SystemScrollEventPosterError.eventCreationFailed }
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: Self.sourceTag)
        event.postToPid(processIdentifier)
    }
}
