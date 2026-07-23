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
        let startedAt = DispatchTime.now().uptimeNanoseconds
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
        var validatedCaptureOverlaps: [Int] = []
        var pacer = AdaptiveCapturePacer(
            initialPulsesPerStep: configuration.pulsesPerStep
        )
        var captureRegion = configuration.region
        var activeSession: (any WindowScrollSession)?
        var route = LongScreenshotScrollRoute.none
        var stopReason = LongScreenshotStopReason.singleFrame
        var viewportRestorationAttempted = false
        var viewportRestorationSucceeded = true
        var environmentRestorationSucceeded = true
        var focusRestorationSucceeded = true
        var pointerRestorationSucceeded = true
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
                if let secondFrame = selection.movedFrame,
                    let analysis = selection.movedAnalysis
                {
                    frames.append(secondFrame)
                    validatedCaptureOverlaps.append(analysis.overlap)
                    captureRegion = freezeAutomaticRegion(
                        requestedRegion: configuration.region,
                        bundleIdentifier: target.bundleIdentifier,
                        before: firstFrame,
                        after: secondFrame,
                        pointPixelScale: pointPixelScale
                    )
                    pacer.observe(
                        overlap: analysis.overlap,
                        viewportHeight: analysis.viewportHeight
                    )
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
                        let checkpoint = captureSession.checkpoint()
                        do {
                            try await activeSession.step(
                                direction: configuration.direction,
                                pulses: pacer.pulsesPerStep
                            )
                        } catch WindowScrollSessionError.boundaryReached {
                            stopReason = .endReached
                            break
                        }
                        guard
                            let verified = try await captureVerifiedFrame(
                                captureSession: captureSession,
                                checkpoint: checkpoint,
                                before: frames.last!,
                                maximumWaitMilliseconds: configuration.settleMilliseconds,
                                quietWindowMilliseconds: quietWindow(
                                    for: activeSession.route
                                ),
                                direction: configuration.direction,
                                region: captureRegion,
                                bundleIdentifier: target.bundleIdentifier,
                                pointPixelScale: pointPixelScale
                            )
                        else {
                            if configuration.stopAtEnd {
                                stopReason = .endReached
                                break
                            }
                            throw LongScreenshotError.overlapUnavailable
                        }
                        frames.append(verified.image)
                        validatedCaptureOverlaps.append(verified.analysis.overlap)
                        pacer.observe(
                            overlap: verified.analysis.overlap,
                            viewportHeight: verified.analysis.viewportHeight
                        )
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
                let restorationCheckpoint = captureSession.checkpoint()
                viewportRestorationSucceeded = await activeSession.restoreViewport()
                if viewportRestorationSucceeded {
                    if let restoredFrame = try? await captureSession.captureAfterMutation(
                        checkpoint: restorationCheckpoint,
                        maximumWaitMilliseconds: configuration.settleMilliseconds
                    ) {
                        viewportRestorationSucceeded = stitcher.hasMatchingViewport(
                            before: firstFrame,
                            after: restoredFrame
                        )
                    } else {
                        viewportRestorationSucceeded = false
                    }
                }
                progress(.restoringEnvironment)
                let environmentRestoration = await activeSession.restoreEnvironment()
                focusRestorationSucceeded = environmentRestoration.focusSucceeded
                pointerRestorationSucceeded = environmentRestoration.pointerSucceeded
                environmentRestorationSucceeded = environmentRestoration.succeeded
            }

            await captureSession.stop()
            progress(.stitching)
            let stitched = try stitcher.stitch(
                capturedFrames: frames,
                direction: configuration.direction,
                region: captureRegion,
                bundleIdentifier: target.bundleIdentifier,
                pointPixelScale: pointPixelScale,
                validatedCaptureOverlaps: validatedCaptureOverlaps
            )
            let elapsedMilliseconds = max(
                1,
                Int(
                    (DispatchTime.now().uptimeNanoseconds - startedAt)
                        / 1_000_000
                )
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
                environmentRestorationSucceeded: environmentRestorationSucceeded,
                focusRestorationSucceeded: focusRestorationSucceeded,
                pointerRestorationSucceeded: pointerRestorationSucceeded,
                captureSource: captureSession.sourceName,
                elapsedMilliseconds: elapsedMilliseconds,
                effectivePixelsPerSecond: Int(
                    (Double(stitched.image.height) * 1_000)
                        / Double(elapsedMilliseconds)
                ),
                finalPulsesPerStep: pacer.pulsesPerStep
            )
        } catch {
            if let activeSession {
                _ = await activeSession.restoreViewport()
                _ = await activeSession.restoreEnvironment()
            }
            await captureSession.stop()
            throw error
        }
    }

    private struct RouteSelection {
        let session: (any WindowScrollSession)?
        let movedFrame: CGImage?
        let movedAnalysis: LongScreenshotMotionAnalysis?
        let reachedBoundary: Bool
    }

    private struct VerifiedFrame {
        let image: CGImage
        let analysis: LongScreenshotMotionAnalysis
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
                let verified = try await probe(
                    session: accessibility,
                    target: target,
                    configuration: configuration,
                    captureSession: captureSession,
                    initialFrame: initialFrame,
                    pointPixelScale: pointPixelScale
                )
                return RouteSelection(
                    session: accessibility,
                    movedFrame: verified.image,
                    movedAnalysis: verified.analysis,
                    reachedBoundary: false
                )
            } catch WindowScrollSessionError.boundaryReached {
                return RouteSelection(
                    session: accessibility,
                    movedFrame: nil,
                    movedAnalysis: nil,
                    reachedBoundary: true
                )
            } catch {
                _ = await accessibility.restoreViewport()
                try await settle(AdaptiveCapturePacer.quietFrameWindowMilliseconds)
            }
        }

        let shouldProbePIDEvent =
            configuration.focusPolicy == .backgroundOnly
            || !LongScreenshotProfileCatalog.prefersForegroundEventRoute(
                target.bundleIdentifier
            )
        if configuration.focusPolicy != .foreground, shouldProbePIDEvent {
            let pidSession = PIDEventScrollSession(
                target: target,
                normalizedScrollPoint: configuration.normalizedScrollPoint
            )
            progress(.probingRoute(.pidEvent))
            do {
                let verified = try await probe(
                    session: pidSession,
                    target: target,
                    configuration: configuration,
                    captureSession: captureSession,
                    initialFrame: initialFrame,
                    pointPixelScale: pointPixelScale,
                    pulses: min(configuration.pulsesPerStep, 12)
                )
                return RouteSelection(
                    session: pidSession,
                    movedFrame: verified.image,
                    movedAnalysis: verified.analysis,
                    reachedBoundary: false
                )
            } catch {
                _ = await pidSession.restoreViewport()
                try await settle(AdaptiveCapturePacer.quietFrameWindowMilliseconds)
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
            let verified = try await probe(
                session: foreground,
                target: target,
                configuration: configuration,
                captureSession: captureSession,
                initialFrame: initialFrame,
                pointPixelScale: pointPixelScale
            )
            return RouteSelection(
                session: foreground,
                movedFrame: verified.image,
                movedAnalysis: verified.analysis,
                reachedBoundary: false
            )
        } catch {
            if error as? WindowScrollSessionError == .boundaryReached
                || error as? WindowScrollSessionError == .noEffect
            {
                return RouteSelection(
                    session: foreground,
                    movedFrame: nil,
                    movedAnalysis: nil,
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
        pointPixelScale: CGFloat,
        pulses: Int? = nil
    ) async throws -> VerifiedFrame {
        let checkpoint = captureSession.checkpoint()
        try await session.step(
            direction: configuration.direction,
            pulses: pulses ?? configuration.pulsesPerStep
        )
        guard
            let verified = try await captureVerifiedFrame(
                captureSession: captureSession,
                checkpoint: checkpoint,
                before: initialFrame,
                maximumWaitMilliseconds: min(
                    configuration.settleMilliseconds,
                    AdaptiveCapturePacer.routeProbeWaitMilliseconds
                ),
                quietWindowMilliseconds: quietWindow(for: session.route),
                direction: configuration.direction,
                region: configuration.region,
                bundleIdentifier: target.bundleIdentifier,
                pointPixelScale: pointPixelScale
            )
        else { throw WindowScrollSessionError.noEffect }
        return verified
    }

    private func captureVerifiedFrame(
        captureSession: WindowCaptureSession,
        checkpoint: UInt64,
        before: CGImage,
        maximumWaitMilliseconds: Int,
        quietWindowMilliseconds: Int,
        direction: LongScreenshotDirection,
        region: LongScreenshotRegion,
        bundleIdentifier: String?,
        pointPixelScale: CGFloat
    ) async throws -> VerifiedFrame? {
        let candidate = try await captureSession.captureAfterMutation(
            checkpoint: checkpoint,
            maximumWaitMilliseconds: maximumWaitMilliseconds,
            quietWindowMilliseconds: quietWindowMilliseconds
        )
        // Only the settled viewport may be committed. An intermediate stream
        // frame no longer represents the session's actual scroll position and
        // would make the next transition discontinuous.
        guard
            let analysis = stitcher.analyzeMotion(
                before: before,
                after: candidate,
                direction: direction,
                region: region,
                bundleIdentifier: bundleIdentifier,
                pointPixelScale: pointPixelScale
            )
        else {
            if stitcher.hasMatchingViewport(before: before, after: candidate) {
                return nil
            }
            throw LongScreenshotError.overlapUnavailable
        }
        guard
            analysis.overlap
                >= AdaptiveCapturePacer.minimumSafeOverlap(
                    viewportHeight: analysis.viewportHeight
                )
        else { throw LongScreenshotError.overlapUnavailable }
        return VerifiedFrame(image: candidate, analysis: analysis)
    }

    private func quietWindow(
        for route: LongScreenshotScrollRoute
    ) -> Int {
        switch route {
        case .pidEvent, .foregroundEvent:
            AdaptiveCapturePacer.eventQuietFrameWindowMilliseconds
        case .accessibilityValue, .none:
            AdaptiveCapturePacer.quietFrameWindowMilliseconds
        }
    }

    private func freezeAutomaticRegion(
        requestedRegion: LongScreenshotRegion,
        bundleIdentifier: String?,
        before: CGImage,
        after: CGImage,
        pointPixelScale: CGFloat
    ) -> LongScreenshotRegion {
        guard requestedRegion == .automatic,
            !LongScreenshotProfileCatalog.contains(bundleIdentifier),
            let layout = try? LongScreenshotLayoutResolver.layout(
                bundleIdentifier: bundleIdentifier,
                pixelWidth: before.width,
                pixelHeight: before.height,
                pointPixelScale: pointPixelScale,
                region: .automatic,
                comparisonFrames: [before, after]
            )
        else { return requestedRegion }
        let width = CGFloat(before.width)
        let height = CGFloat(before.height)
        return .normalized(
            CGRect(
                x: layout.transcript.minX / width,
                y: layout.transcript.minY / height,
                width: layout.transcript.width / width,
                height: layout.transcript.height / height
            )
        )
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
