import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
public final class LongScreenshotCoordinator {
    private let targetResolver: WindowTargetResolver
    private let stitcher: LongScreenshotStitcher

    public init() {
        targetResolver = WindowTargetResolver()
        stitcher = LongScreenshotStitcher()
    }

    public func capture(
        selector: WindowTargetSelector,
        configuration: LongScreenshotConfiguration = LongScreenshotConfiguration(),
        progress: @MainActor (LongScreenshotPhase) -> Void = { _ in }
    ) async throws -> LongScreenshotResult {
        progress(.resolvingTarget)
        let target = try await targetResolver.resolve(selector)
        return try await capture(
            target: target,
            configuration: configuration,
            progress: progress
        )
    }

    public func capture(
        target: WindowCaptureTarget,
        configuration: LongScreenshotConfiguration = LongScreenshotConfiguration(),
        progress: @MainActor (LongScreenshotPhase) -> Void = { _ in }
    ) async throws -> LongScreenshotResult {
        try validate(configuration)
        guard CGPreflightScreenCaptureAccess() else {
            throw LongScreenshotError.screenCapturePermissionMissing
        }
        guard configuration.frameCount == 1 || AXIsProcessTrusted() else {
            throw LongScreenshotError.accessibilityPermissionMissing
        }

        progress(.preparing)
        let captureSession = try await WindowCaptureSession(target: target)
        let firstFrame = try await captureSession.capture()
        let pointPixelScale =
            target.frame.width > 0
            ? CGFloat(firstFrame.width) / target.frame.width
            : 1
        var frames = [firstFrame]
        var activeSession: (any WindowScrollSession)?
        var route = LongScreenshotScrollRoute.none
        var stopReason = LongScreenshotStopReason.singleFrame
        var viewportRestorationAttempted = false
        var viewportRestorationSucceeded = true
        var environmentRestorationSucceeded = true
        var targetWasActivated = false
        var pointerWasMoved = false
        progress(.capturing(current: 1, total: configuration.frameCount))

        do {
            if configuration.frameCount > 1 {
                let selection = try await selectRoute(
                    target: target,
                    configuration: configuration,
                    captureSession: captureSession,
                    initialFrame: firstFrame,
                    pointPixelScale: pointPixelScale,
                    progress: progress
                )
                activeSession = selection.session
                route = selection.session?.route ?? .none
                if let secondFrame = selection.movedFrame {
                    frames.append(secondFrame)
                    progress(
                        .capturing(
                            current: frames.count,
                            total: configuration.frameCount
                        ))
                }
                stopReason =
                    selection.reachedBoundary
                    ? .endReached
                    : .frameLimitReached

                if let activeSession, !selection.reachedBoundary {
                    while frames.count < configuration.frameCount {
                        try Task.checkCancellation()
                        do {
                            try await activeSession.step(
                                direction: configuration.direction,
                                pulses: configuration.pulsesPerStep
                            )
                        } catch WindowScrollSessionError.boundaryReached {
                            stopReason = .endReached
                            break
                        }
                        try await settle(configuration.settleMilliseconds)
                        let next = try await captureSession.capture()
                        if configuration.stopAtEnd,
                            !stitcher.hasPlausibleMotion(
                                before: frames.last!,
                                after: next,
                                direction: configuration.direction,
                                region: configuration.region,
                                bundleIdentifier: target.bundleIdentifier,
                                pointPixelScale: pointPixelScale
                            )
                        {
                            stopReason = .endReached
                            break
                        }
                        frames.append(next)
                        progress(
                            .capturing(
                                current: frames.count,
                                total: configuration.frameCount
                            ))
                    }
                    if frames.count == configuration.frameCount {
                        stopReason = .frameLimitReached
                    }
                }
            }

            if let activeSession {
                targetWasActivated = activeSession.targetWasActivated
                pointerWasMoved = activeSession.pointerWasMoved
                viewportRestorationAttempted = configuration.frameCount > 1
                progress(.restoringViewport)
                viewportRestorationSucceeded = await activeSession.restoreViewport()
                if viewportRestorationSucceeded {
                    try await settle(configuration.settleMilliseconds)
                    if let restoredFrame = try? await captureSession.capture() {
                        viewportRestorationSucceeded = stitcher.hasMatchingViewport(
                            before: firstFrame,
                            after: restoredFrame
                        )
                    } else {
                        viewportRestorationSucceeded = false
                    }
                }
                progress(.restoringEnvironment)
                environmentRestorationSucceeded = await activeSession.restoreEnvironment()
            }

            progress(.stitching)
            let stitched = try stitcher.stitch(
                capturedFrames: frames,
                direction: configuration.direction,
                region: configuration.region,
                bundleIdentifier: target.bundleIdentifier,
                pointPixelScale: pointPixelScale
            )
            return LongScreenshotResult(
                image: stitched.image,
                target: target,
                capturedFrameCount: frames.count,
                overlaps: stitched.overlaps,
                regionInPixels: stitched.regionInPixels,
                scrollRoute: route,
                stopReason: stopReason,
                targetWasActivated: targetWasActivated,
                pointerWasMoved: pointerWasMoved,
                viewportRestorationAttempted: viewportRestorationAttempted,
                viewportRestorationSucceeded: viewportRestorationSucceeded,
                environmentRestorationSucceeded: environmentRestorationSucceeded
            )
        } catch {
            if let activeSession {
                _ = await activeSession.restoreViewport()
                _ = await activeSession.restoreEnvironment()
            }
            throw error
        }
    }

    private struct RouteSelection {
        let session: (any WindowScrollSession)?
        let movedFrame: CGImage?
        let reachedBoundary: Bool
    }

    private func selectRoute(
        target: WindowCaptureTarget,
        configuration: LongScreenshotConfiguration,
        captureSession: WindowCaptureSession,
        initialFrame: CGImage,
        pointPixelScale: CGFloat,
        progress: @MainActor (LongScreenshotPhase) -> Void
    ) async throws -> RouteSelection {
        if configuration.focusPolicy != .foreground,
            let accessibility = try AccessibilityValueScrollSession.make(
                target: target,
                normalizedScrollPoint: configuration.normalizedScrollPoint
            )
        {
            progress(.probingRoute(.accessibilityValue))
            do {
                let frame = try await probe(
                    session: accessibility,
                    target: target,
                    configuration: configuration,
                    captureSession: captureSession,
                    initialFrame: initialFrame,
                    pointPixelScale: pointPixelScale
                )
                return RouteSelection(
                    session: accessibility,
                    movedFrame: frame,
                    reachedBoundary: false
                )
            } catch WindowScrollSessionError.boundaryReached {
                return RouteSelection(
                    session: accessibility,
                    movedFrame: nil,
                    reachedBoundary: true
                )
            } catch {
                _ = await accessibility.restoreViewport()
                try await settle(configuration.settleMilliseconds)
            }
        }

        if configuration.focusPolicy != .foreground {
            let pidSession = PIDEventScrollSession(
                target: target,
                normalizedScrollPoint: configuration.normalizedScrollPoint
            )
            progress(.probingRoute(.pidEvent))
            do {
                let frame = try await probe(
                    session: pidSession,
                    target: target,
                    configuration: configuration,
                    captureSession: captureSession,
                    initialFrame: initialFrame,
                    pointPixelScale: pointPixelScale
                )
                return RouteSelection(
                    session: pidSession,
                    movedFrame: frame,
                    reachedBoundary: false
                )
            } catch {
                _ = await pidSession.restoreViewport()
                try await settle(configuration.settleMilliseconds)
            }
        }

        guard configuration.focusPolicy != .backgroundOnly else {
            throw LongScreenshotError.backgroundScrollUnavailable
        }

        let foreground = ForegroundEventScrollSession(target: target)
        try await foreground.prepare(
            normalizedScrollPoint: configuration.normalizedScrollPoint,
            allowActivation: configuration.focusPolicy == .backgroundFirst
        )
        progress(.probingRoute(.foregroundEvent))
        do {
            let frame = try await probe(
                session: foreground,
                target: target,
                configuration: configuration,
                captureSession: captureSession,
                initialFrame: initialFrame,
                pointPixelScale: pointPixelScale
            )
            return RouteSelection(
                session: foreground,
                movedFrame: frame,
                reachedBoundary: false
            )
        } catch {
            if error as? WindowScrollSessionError == .boundaryReached
                || error as? WindowScrollSessionError == .noEffect
            {
                return RouteSelection(
                    session: foreground,
                    movedFrame: nil,
                    reachedBoundary: true
                )
            }
            _ = await foreground.restoreViewport()
            _ = await foreground.restoreEnvironment()
            throw error
        }
    }

    private func probe(
        session: any WindowScrollSession,
        target: WindowCaptureTarget,
        configuration: LongScreenshotConfiguration,
        captureSession: WindowCaptureSession,
        initialFrame: CGImage,
        pointPixelScale: CGFloat
    ) async throws -> CGImage {
        try await session.step(
            direction: configuration.direction,
            pulses: configuration.pulsesPerStep
        )
        try await settle(configuration.settleMilliseconds)
        let candidate = try await captureSession.capture()
        guard
            stitcher.hasPlausibleMotion(
                before: initialFrame,
                after: candidate,
                direction: configuration.direction,
                region: configuration.region,
                bundleIdentifier: target.bundleIdentifier,
                pointPixelScale: pointPixelScale
            )
        else { throw WindowScrollSessionError.noEffect }
        return candidate
    }

    private func settle(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func validate(_ configuration: LongScreenshotConfiguration) throws {
        guard (1...100).contains(configuration.frameCount),
            (1...240).contains(configuration.pulsesPerStep),
            (100...5_000).contains(configuration.settleMilliseconds),
            (0...1).contains(configuration.normalizedScrollPoint.x),
            (0...1).contains(configuration.normalizedScrollPoint.y)
        else { throw LongScreenshotError.invalidConfiguration }
    }
}
