import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LongviewCore

enum WindowScrollSessionError: Error, Equatable {
    case boundaryReached
    case noEffect
    case routeUnavailable
}

@MainActor
private func uncancellableDelay(milliseconds: Int) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds)
        ) {
            continuation.resume()
        }
    }
}

@MainActor
protocol WindowScrollSession: AnyObject {
    var route: LongScreenshotScrollRoute { get }
    var targetWasActivated: Bool { get }
    var pointerWasMoved: Bool { get }

    func step(
        direction: LongScreenshotDirection,
        pulses: Int
    ) async throws
    func restoreViewport() async -> Bool
    func restoreEnvironment() async -> Bool
}

@MainActor
final class AccessibilityValueScrollSession: WindowScrollSession {
    let route = LongScreenshotScrollRoute.accessibilityValue
    let targetWasActivated = false
    let pointerWasMoved = false

    private let target: WindowCaptureTarget
    private let scrollBar: AXUIElement
    private let minimumValue: Double
    private let maximumValue: Double
    private let originalValue: Double
    private let supportedActions: Set<String>

    private init(
        target: WindowCaptureTarget,
        scrollBar: AXUIElement,
        minimumValue: Double,
        maximumValue: Double,
        originalValue: Double,
        supportedActions: Set<String>
    ) {
        self.target = target
        self.scrollBar = scrollBar
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.originalValue = originalValue
        self.supportedActions = supportedActions
    }

    static func make(
        target: WindowCaptureTarget,
        normalizedScrollPoint: CGPoint
    ) throws -> AccessibilityValueScrollSession? {
        guard AXIsProcessTrusted() else {
            throw LongScreenshotError.accessibilityPermissionMissing
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.0)
        guard let window = matchingWindow(in: application, target: target) else {
            return nil
        }
        let screenPoint = CGPoint(
            x: target.frame.minX + target.frame.width * normalizedScrollPoint.x,
            y: target.frame.minY + target.frame.height * normalizedScrollPoint.y
        )
        guard let candidate = scrollBarCandidate(in: window, screenPoint: screenPoint),
            let value = numberAttribute(kAXValueAttribute as CFString, from: candidate.element)
        else { return nil }
        let minimum =
            numberAttribute(
                kAXMinValueAttribute as CFString,
                from: candidate.element
            ) ?? 0
        let maximum =
            numberAttribute(
                kAXMaxValueAttribute as CFString,
                from: candidate.element
            ) ?? 1
        guard maximum > minimum else { return nil }
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                candidate.element,
                kAXValueAttribute as CFString,
                &settable
            ) == .success,
            settable.boolValue
        else { return nil }
        return AccessibilityValueScrollSession(
            target: target,
            scrollBar: candidate.element,
            minimumValue: minimum,
            maximumValue: maximum,
            originalValue: value,
            supportedActions: actionNames(from: candidate.element)
        )
    }

    func step(
        direction: LongScreenshotDirection,
        pulses: Int
    ) async throws {
        guard
            let current = Self.numberAttribute(
                kAXValueAttribute as CFString,
                from: scrollBar
            )
        else { throw WindowScrollSessionError.routeUnavailable }
        let action =
            direction == .up
            ? (kAXDecrementAction as String)
            : (kAXIncrementAction as String)
        if supportedActions.contains(action) {
            let actionCount = max(1, min(12, pulses / 4))
            for _ in 0..<actionCount {
                try Task.checkCancellation()
                guard
                    AXUIElementPerformAction(
                        scrollBar,
                        action as CFString
                    ) == .success
                else { break }
                try await Task.sleep(for: .milliseconds(12))
            }
        } else {
            let span = maximumValue - minimumValue
            let normalizedStep = min(0.05, max(0.01, Double(pulses) / 900))
            let signed = direction == .up ? -1.0 : 1.0
            let proposed = min(
                maximumValue,
                max(minimumValue, current + signed * normalizedStep * span)
            )
            guard abs(proposed - current) > 0.000_001 else {
                throw WindowScrollSessionError.boundaryReached
            }
            guard
                AXUIElementSetAttributeValue(
                    scrollBar,
                    kAXValueAttribute as CFString,
                    NSNumber(value: proposed)
                ) == .success
            else { throw WindowScrollSessionError.noEffect }
        }
        try await Task.sleep(for: .milliseconds(40))
        guard
            let observed = Self.numberAttribute(
                kAXValueAttribute as CFString,
                from: scrollBar
            ),
            abs(observed - current) > 0.000_001
        else { throw WindowScrollSessionError.noEffect }
    }

    func restoreViewport() async -> Bool {
        guard
            AXUIElementSetAttributeValue(
                scrollBar,
                kAXValueAttribute as CFString,
                NSNumber(value: originalValue)
            ) == .success
        else { return false }
        try? await Task.sleep(for: .milliseconds(40))
        guard
            let restored = Self.numberAttribute(
                kAXValueAttribute as CFString,
                from: scrollBar
            )
        else { return false }
        return abs(restored - originalValue) <= 0.000_001
    }

    func restoreEnvironment() async -> Bool { true }

    private struct ScrollBarCandidate {
        let element: AXUIElement
        let containerFrame: CGRect
        let containsScrollPoint: Bool
    }

    private static func scrollBarCandidate(
        in root: AXUIElement,
        screenPoint: CGPoint
    ) -> ScrollBarCandidate? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var candidates: [ScrollBarCandidate] = []
        var visited = Set<CFHashCode>()
        var examined = 0

        while !queue.isEmpty, examined < 2_048 {
            let (element, depth) = queue.removeFirst()
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            examined += 1
            let frame = frameAttribute(from: element) ?? .zero
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element)

            if let vertical = elementAttribute(
                kAXVerticalScrollBarAttribute as CFString,
                from: element
            ) {
                candidates.append(
                    ScrollBarCandidate(
                        element: vertical,
                        containerFrame: frame,
                        containsScrollPoint: frame.contains(screenPoint)
                    ))
            } else if role == (kAXScrollBarRole as String),
                isVerticalScrollBar(element)
            {
                let parent = elementAttribute(kAXParentAttribute as CFString, from: element)
                let parentFrame = parent.flatMap(frameAttribute(from:)) ?? frame
                candidates.append(
                    ScrollBarCandidate(
                        element: element,
                        containerFrame: parentFrame,
                        containsScrollPoint: parentFrame.contains(screenPoint)
                    ))
            }

            guard depth < 14 else { continue }
            for child in elementArrayAttribute(
                kAXChildrenAttribute as CFString,
                from: element
            ) {
                queue.append((child, depth + 1))
            }
        }

        return candidates.max { lhs, rhs in
            if lhs.containsScrollPoint != rhs.containsScrollPoint {
                return !lhs.containsScrollPoint && rhs.containsScrollPoint
            }
            return lhs.containerFrame.width * lhs.containerFrame.height
                < rhs.containerFrame.width * rhs.containerFrame.height
        }
    }

    private static func isVerticalScrollBar(_ element: AXUIElement) -> Bool {
        if let orientation = stringAttribute(
            kAXOrientationAttribute as CFString,
            from: element
        ) {
            return orientation == (kAXVerticalOrientationValue as String)
        }
        guard let frame = frameAttribute(from: element) else { return false }
        return frame.height > frame.width
    }

    private static func matchingWindow(
        in application: AXUIElement,
        target: WindowCaptureTarget
    ) -> AXUIElement? {
        let windows = elementArrayAttribute(kAXWindowsAttribute as CFString, from: application)
        let frameMatches = windows.filter {
            frameDistance(frameAttribute(from: $0), target.frame) <= 8
        }
        guard !frameMatches.isEmpty else { return nil }

        if let title = target.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            let titleMatches = frameMatches.filter {
                stringAttribute(kAXTitleAttribute as CFString, from: $0) == title
            }
            if titleMatches.count == 1 {
                return titleMatches[0]
            }
            if titleMatches.count > 1 {
                return nil
            }
        }

        return frameMatches.count == 1 ? frameMatches[0] : nil
    }

    private static func frameDistance(_ frame: CGRect?, _ target: CGRect) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        return abs(frame.minX - target.minX)
            + abs(frame.minY - target.minY)
            + abs(frame.width - target.width)
            + abs(frame.height - target.height)
    }

    fileprivate static func elementArrayAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self)
        }
    }

    fileprivate static func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    fileprivate static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }

    fileprivate static func numberAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let number = value as? NSNumber
        else { return nil }
        return number.doubleValue
    }

    private static func actionNames(from element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
            let names
        else { return [] }
        return Set((names as? [String]) ?? [])
    }

    fileprivate static func frameAttribute(from element: AXUIElement) -> CGRect? {
        guard
            let position = axValueAttribute(
                kAXPositionAttribute as CFString,
                type: .cgPoint,
                from: element
            ) as CGPoint?,
            let size = axValueAttribute(
                kAXSizeAttribute as CFString,
                type: .cgSize,
                from: element
            ) as CGSize?
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axValueAttribute<T>(
        _ attribute: CFString,
        type: AXValueType,
        from element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(axValue, type, pointer) else { return nil }
        return pointer.pointee
    }
}

@MainActor
final class PIDEventScrollSession: WindowScrollSession {
    let route = LongScreenshotScrollRoute.pidEvent
    let targetWasActivated = false
    let pointerWasMoved = false

    private let target: WindowCaptureTarget
    private let location: CGPoint
    private let poster = SystemScrollEventPoster()
    private var completedSteps = 0
    private var pulsesPerStep = 0
    private var lastDirection = LongScreenshotDirection.up

    init(target: WindowCaptureTarget, normalizedScrollPoint: CGPoint) {
        self.target = target
        location = CGPoint(
            x: target.frame.minX + target.frame.width * normalizedScrollPoint.x,
            y: target.frame.minY + target.frame.height * normalizedScrollPoint.y
        )
    }

    func step(
        direction: LongScreenshotDirection,
        pulses: Int
    ) async throws {
        lastDirection = direction
        pulsesPerStep = pulses
        try await post(
            direction: direction,
            count: pulses,
            honorCancellation: true
        )
        completedSteps += 1
    }

    func restoreViewport() async -> Bool {
        guard completedSteps > 0 else { return true }
        do {
            try await post(
                direction: lastDirection == .up ? .down : .up,
                count: pulsesPerStep * completedSteps,
                honorCancellation: false
            )
            return true
        } catch {
            return false
        }
    }

    func restoreEnvironment() async -> Bool { true }

    private func post(
        direction: LongScreenshotDirection,
        count: Int,
        honorCancellation: Bool
    ) async throws {
        let magnitude = AutoScrollSpeed.fast.pixelsPerPulse
        let delta = direction == .up ? magnitude : -magnitude
        for _ in 0..<count {
            if honorCancellation {
                try Task.checkCancellation()
            }
            try poster.postPixelDelta(
                delta,
                to: target.processIdentifier,
                at: location
            )
            if honorCancellation {
                try await Task.sleep(for: .milliseconds(14))
            } else {
                await uncancellableDelay(milliseconds: 14)
            }
        }
    }
}

@MainActor
private struct ExplicitWindowScrollTargetLeaseValidator: ScrollTargetLeaseValidating {
    let target: WindowCaptureTarget

    func isValid(_ candidate: AutoScrollTarget) -> Bool {
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier,
            candidate.processIdentifier == target.processIdentifier,
            candidate.windowNumber == target.windowID,
            let pointerLocation = CGEvent(source: nil)?.location,
            target.frame.contains(pointerLocation),
            let raw = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                target.windowID
            ) as? [[String: Any]],
            let window = raw.first,
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == target.processIdentifier,
            let frame = frame(from: window[kCGWindowBounds as String]),
            framesMatch(frame, target.frame)
        else { return false }
        return true
    }

    private func frame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
            let x = (bounds["X"] as? NSNumber)?.doubleValue,
            let y = (bounds["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }
}

@MainActor
final class ForegroundEventScrollSession: WindowScrollSession {
    let route = LongScreenshotScrollRoute.foregroundEvent
    private(set) var targetWasActivated = false
    private(set) var pointerWasMoved = false

    private let target: WindowCaptureTarget
    private let originalFrontmost: NSRunningApplication?
    private let originalPointer: CGPoint?
    private let pulseController: AutoScrollPulseController
    private var scrollTarget: AutoScrollTarget?
    private var scrollLocation: CGPoint?
    private var completedSteps = 0
    private var pulsesPerStep = 0
    private var lastDirection = LongScreenshotDirection.up

    init(target: WindowCaptureTarget) {
        self.target = target
        originalFrontmost = NSWorkspace.shared.frontmostApplication
        originalPointer = CGEvent(source: nil)?.location
        pulseController = AutoScrollPulseController(
            leaseValidator: ExplicitWindowScrollTargetLeaseValidator(target: target)
        )
    }

    func prepare(
        normalizedScrollPoint: CGPoint,
        allowActivation: Bool
    ) async throws {
        do {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID != target.processIdentifier {
                guard allowActivation else {
                    throw LongScreenshotError.foregroundRequired
                }
                // Cross-Space activation is not reliably reversible through
                // public APIs. Refuse before changing focus.
                guard target.isOnScreen else {
                    throw LongScreenshotError.foregroundWindowUnavailable
                }
                guard
                    let application = NSRunningApplication(
                        processIdentifier: target.processIdentifier
                    )
                else { throw LongScreenshotError.targetApplicationUnavailable }
                _ = Self.raiseMatchingWindow(target)
                guard application.activate(options: [.activateAllWindows]) else {
                    throw LongScreenshotError.foregroundActivationFailed
                }
                targetWasActivated = true
                try await waitUntilFrontmost()
                _ = Self.raiseMatchingWindow(target)
            }

            guard Self.isVisibleOnActiveSpace(target) else {
                throw LongScreenshotError.foregroundWindowUnavailable
            }

            let point = CGPoint(
                x: target.frame.minX + target.frame.width * normalizedScrollPoint.x,
                y: target.frame.minY + target.frame.height * normalizedScrollPoint.y
            )
            scrollLocation = point
            guard CGWarpMouseCursorPosition(point) == .success else {
                throw LongScreenshotError.foregroundActivationFailed
            }
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            pointerWasMoved =
                originalPointer.map { hypot($0.x - point.x, $0.y - point.y) > 0.5 }
                ?? true
            try await Task.sleep(for: .milliseconds(120))
            scrollTarget = AutoScrollTarget(
                processIdentifier: target.processIdentifier,
                bundleIdentifier: target.bundleIdentifier,
                applicationName: target.applicationName,
                windowFrame: target.frame,
                windowNumber: target.windowID
            )
        } catch {
            _ = await restoreEnvironment()
            throw error
        }
    }

    func step(
        direction: LongScreenshotDirection,
        pulses: Int
    ) async throws {
        guard let scrollTarget else { throw WindowScrollSessionError.routeUnavailable }
        lastDirection = direction
        pulsesPerStep = pulses
        try await post(
            target: scrollTarget,
            direction: direction,
            count: pulses,
            honorCancellation: true
        )
        completedSteps += 1
    }

    func restoreViewport() async -> Bool {
        guard completedSteps > 0, let scrollTarget else { return completedSteps == 0 }
        guard await reacquireRestorationLeaseIfNeeded() else { return false }
        do {
            try await post(
                target: scrollTarget,
                direction: lastDirection == .up ? .down : .up,
                count: pulsesPerStep * completedSteps,
                honorCancellation: false
            )
            return true
        } catch {
            return false
        }
    }

    private func reacquireRestorationLeaseIfNeeded() async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            != target.processIdentifier
        {
            guard targetWasActivated,
                target.isOnScreen,
                let application = NSRunningApplication(
                    processIdentifier: target.processIdentifier
                ),
                application.activate(options: [.activateAllWindows]),
                await waitUntilFrontmost(
                    processIdentifier: target.processIdentifier
                )
            else { return false }
        }
        if let scrollLocation,
            CGWarpMouseCursorPosition(scrollLocation) != .success
        {
            return false
        }
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        return true
    }

    func restoreEnvironment() async -> Bool {
        var focusRestored = true
        if targetWasActivated,
            let originalFrontmost,
            !originalFrontmost.isTerminated,
            originalFrontmost.processIdentifier != target.processIdentifier
        {
            focusRestored = originalFrontmost.activate(options: [.activateAllWindows])
            if focusRestored {
                focusRestored = await waitUntilFrontmost(
                    processIdentifier: originalFrontmost.processIdentifier
                )
            }
        }
        var pointerRestored = true
        if let originalPointer, pointerWasMoved {
            pointerRestored = CGWarpMouseCursorPosition(originalPointer) == .success
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            if pointerRestored {
                await uncancellableDelay(milliseconds: 20)
                if let observed = CGEvent(source: nil)?.location {
                    pointerRestored =
                        hypot(
                            observed.x - originalPointer.x,
                            observed.y - originalPointer.y
                        ) <= 1
                } else {
                    pointerRestored = false
                }
            }
        }
        return pointerRestored && focusRestored
    }

    private func post(
        target: AutoScrollTarget,
        direction: LongScreenshotDirection,
        count: Int,
        honorCancellation: Bool
    ) async throws {
        for _ in 0..<count {
            if honorCancellation {
                try Task.checkCancellation()
            }
            do {
                try pulseController.postPulse(
                    target: target,
                    direction: direction == .up ? .up : .down,
                    speed: .fast
                )
            } catch AutoScrollPulseControllerError.targetLeaseInvalid {
                throw LongScreenshotError.targetChanged
            }
            if honorCancellation {
                try await Task.sleep(for: .milliseconds(14))
            } else {
                await uncancellableDelay(milliseconds: 14)
            }
        }
    }

    private func waitUntilFrontmost() async throws {
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LongScreenshotError.foregroundActivationFailed
    }

    private func waitUntilFrontmost(processIdentifier: pid_t) async -> Bool {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier
            {
                return true
            }
            if Task.isCancelled {
                await uncancellableDelay(milliseconds: 50)
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
            == processIdentifier
    }

    private static func isVisibleOnActiveSpace(_ target: WindowCaptureTarget) -> Bool {
        guard
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }
        return raw.contains { window in
            (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                == target.windowID
                && (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == target.processIdentifier
        }
    }

    private static func raiseMatchingWindow(_ target: WindowCaptureTarget) -> Bool {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        let windows = AccessibilityValueScrollSession.elementArrayAttribute(
            kAXWindowsAttribute as CFString,
            from: application
        )
        guard
            let window = windows.min(by: {
                frameDistance(
                    AccessibilityValueScrollSession.frameAttribute(from: $0),
                    target.frame
                )
                    < frameDistance(
                        AccessibilityValueScrollSession.frameAttribute(from: $1),
                        target.frame
                    )
            }),
            frameDistance(
                AccessibilityValueScrollSession.frameAttribute(from: window),
                target.frame
            ) <= 8
        else { return false }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private static func frameDistance(_ frame: CGRect?, _ target: CGRect) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        return abs(frame.minX - target.minX)
            + abs(frame.minY - target.minY)
            + abs(frame.width - target.width)
            + abs(frame.height - target.height)
    }
}
