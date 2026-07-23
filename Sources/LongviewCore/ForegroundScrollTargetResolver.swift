import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum ForegroundScrollTargetResolverError: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case frontmostApplicationUnavailable
    case excludedApplication
    case focusedWindowUnavailable
    case pointerLocationUnavailable
    case pointerOutsideFocusedWindow
}

@MainActor
public struct ForegroundScrollTargetResolver {
    public let excludedBundleIdentifiers: Set<String>

    public init(excludedBundleIdentifiers: Set<String> = []) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    public func resolve() throws -> AutoScrollTarget {
        guard AXIsProcessTrusted() else {
            throw ForegroundScrollTargetResolverError.accessibilityPermissionMissing
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw ForegroundScrollTargetResolverError.frontmostApplicationUnavailable
        }
        if let bundleIdentifier = application.bundleIdentifier,
            excludedBundleIdentifiers.contains(bundleIdentifier)
        {
            throw ForegroundScrollTargetResolverError.excludedApplication
        }

        guard
            let windowFrame = focusedWindowFrame(
                processIdentifier: application.processIdentifier
            )
        else {
            throw ForegroundScrollTargetResolverError.focusedWindowUnavailable
        }
        guard let pointerLocation = CGEvent(source: nil)?.location else {
            throw ForegroundScrollTargetResolverError.pointerLocationUnavailable
        }
        guard windowFrame.contains(pointerLocation) else {
            throw ForegroundScrollTargetResolverError.pointerOutsideFocusedWindow
        }

        return AutoScrollTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? "当前软件",
            windowFrame: windowFrame,
            windowNumber: windowNumber(
                processIdentifier: application.processIdentifier,
                frame: windowFrame
            )
        )
    }

    fileprivate func focusedWindowFrame(processIdentifier: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(processIdentifier)
        let window =
            copyElement(kAXFocusedWindowAttribute as CFString, from: application)
            ?? firstWindow(from: application)
        guard let window,
            let position = pointAttribute(kAXPositionAttribute as CFString, from: window),
            let size = sizeAttribute(kAXSizeAttribute as CFString, from: window),
            size.width > 0,
            size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    fileprivate func windowNumber(
        processIdentifier: pid_t,
        frame: CGRect
    ) -> CGWindowID? {
        guard
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let candidates: [CGWindowID] = raw.compactMap { window in
            guard
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == processIdentifier,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let candidateFrame = windowFrame(
                    from: window[kCGWindowBounds as String]
                ),
                framesMatch(candidateFrame, frame),
                let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { return nil }
            return number
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func windowFrame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
            let x = (bounds["X"] as? NSNumber)?.doubleValue,
            let y = (bounds["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func firstWindow(from application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }
        let windows = value as! CFArray
        guard CFArrayGetCount(windows) > 0 else { return nil }
        return unsafeBitCast(CFArrayGetValueAtIndex(windows, 0), to: AXUIElement.self)
    }

    private func copyElement(
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

    private func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}

@MainActor
public protocol ScrollTargetLeaseValidating {
    func isValid(_ target: AutoScrollTarget) -> Bool
}

@MainActor
public struct SystemScrollTargetLeaseValidator: ScrollTargetLeaseValidating {
    public init() {}

    public func isValid(_ target: AutoScrollTarget) -> Bool {
        guard AXIsProcessTrusted(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier
        else { return false }
        let expectedFrame = target.windowFrame
        let resolver = ForegroundScrollTargetResolver()
        guard
            let currentFrame = resolver.focusedWindowFrame(
                processIdentifier: target.processIdentifier
            ),
            framesMatch(currentFrame, expectedFrame)
        else { return false }
        guard let pointerLocation = CGEvent(source: nil)?.location,
            currentFrame.contains(pointerLocation)
        else { return false }
        if let expectedWindowNumber = target.windowNumber {
            return resolver.windowNumber(
                processIdentifier: target.processIdentifier,
                frame: currentFrame
            ) == expectedWindowNumber
        }
        return true
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }
}
