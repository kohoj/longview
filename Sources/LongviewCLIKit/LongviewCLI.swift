import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LongviewCapture
import LongviewCore

private struct CLIExecutionFailure: Error {
    let exitCode: Int32
    let body: CLIErrorBody
}

@MainActor
public enum LongviewCLI {
    public static func main(arguments: [String] = CommandLine.arguments) async -> Int32 {
        let invocation: CLIInvocation
        do {
            invocation = try CLIArgumentParser.parse(arguments)
        } catch {
            let output = CLIOutput.terminal(prettyPrinted: arguments.contains("--pretty"))
            output.failure(command: inferredCommand(from: arguments), error: usageError(error))
            return 64
        }

        let output = CLIOutput.terminal(
            prettyPrinted: invocation.globalOptions.prettyPrinted
        )
        do {
            try await run(invocation, output: output)
            return 0
        } catch let failure as CLIExecutionFailure {
            output.failure(command: invocation.command.name, error: failure.body)
            return failure.exitCode
        } catch is CancellationError {
            output.failure(
                command: invocation.command.name,
                error: CLIErrorBody(code: "canceled", message: "Command canceled.")
            )
            return 130
        } catch {
            let failure = map(error)
            output.failure(command: invocation.command.name, error: failure.body)
            return failure.exitCode
        }
    }

    public static func run(_ invocation: CLIInvocation, output: CLIOutput) async throws {
        switch invocation.command {
        case .capabilities:
            try output.success(command: "capabilities", result: capabilities())
        case .doctor:
            try output.success(command: "doctor", result: Doctor.inspect())
        case .windows(let options):
            let windows = try await WindowTargetResolver().list(
                bundleIdentifier: options.bundleIdentifier
            )
            try output.success(
                command: "windows",
                result: WindowListResult(
                    windows: windows.map {
                        TargetResult(target: $0, includeTitle: options.includeTitles)
                    })
            )
        case .target:
            let target = try ForegroundScrollTargetResolver().resolve()
            try output.success(command: "target", result: TargetResult(target: target))
        case .scroll(let options):
            try await runScroll(
                options,
                emitEvents: invocation.globalOptions.emitEvents,
                output: output
            )
        case .longshot(let options):
            try await runLongshot(
                options,
                emitEvents: invocation.globalOptions.emitEvents,
                output: output
            )
        case .version:
            try output.success(
                command: "version",
                result: VersionResult(
                    version: LongviewBuildInfo.version,
                    schemaVersion: CLIProtocol.schemaVersion
                )
            )
        case .help:
            output.text(helpText)
        }
    }

    private static func capabilities() -> CapabilityResult {
        CapabilityResult(
            cliVersion: LongviewBuildInfo.version,
            schemaVersion: CLIProtocol.schemaVersion,
            commands: [
                "capabilities", "doctor", "windows", "target", "scroll", "longshot", "version", "help",
            ],
            permissions: PermissionResult(
                accessibility: AXIsProcessTrusted(),
                screenCapture: CGPreflightScreenCaptureAccess()
            ),
            mutationBoundary: [
                "accessibility-scrollbar-action-or-value",
                "pid-targeted-vertical-pixel-scroll",
                "temporary-focus-and-vertical-pixel-scroll",
            ],
            longshot: CapabilityResult.LongshotCapability(
                targetScope: "shareable-layer-zero-window",
                targetSelectors: ["window-id", "bundle-id", "frontmost-bundle"],
                captureRoute: "ScreenCaptureKit.desktopIndependentWindow",
                backgroundCapture: true,
                backgroundScroll: "conditional-on-live-AX-scrollbar-or-app-honored-PID-event",
                knownProfiles: LongScreenshotProfileCatalog.knownBundleIdentifiers,
                defaultFocusPolicy: LongScreenshotFocusPolicy.backgroundFirst.rawValue,
                focusPolicies: LongScreenshotFocusPolicy.allCases.map(\.rawValue),
                scrollRoutes: [
                    LongScreenshotScrollRoute.accessibilityValue.rawValue,
                    LongScreenshotScrollRoute.pidEvent.rawValue,
                    LongScreenshotScrollRoute.foregroundEvent.rawValue,
                ],
                regionModes: ["auto", "full", "profile", "normalized-rectangle"],
                directions: LongScreenshotDirection.allCases.map(\.rawValue),
                frameRange: [1, 100],
                pulsesPerStepRange: [1, 240],
                settleMillisecondsRange: [100, 5_000],
                outputFormat: "png",
                restoration: "attempted-and-capture-verified",
                limitations: [
                    "protected-or-DRM-content-may-be-absent-or-black",
                    "off-active-Space-foreground-fallback-is-refused",
                    "hidden-or-occluded-windows-may-not-render-updated-content",
                    "apps-may-ignore-synthetic-scroll-events",
                    "nested-scroll-layouts-may-require-explicit-scroll-point-and-region",
                ]
            )
        )
    }

    private static func runScroll(
        _ options: ScrollOptions,
        emitEvents: Bool,
        output: CLIOutput
    ) async throws {
        let target = try ForegroundScrollTargetResolver().resolve()
        try validateTarget(target, expectedBundleIdentifier: options.expectedBundleIdentifier)
        let totalPulses = pulseCount(for: options)
        let start = ContinuousClock.now

        if options.dryRun {
            let result = ScrollResult(
                target: TargetResult(target: target),
                direction: options.direction.rawValue,
                speed: options.speed.rawValue,
                emittedPulses: 0,
                pixelsPerPulse: options.speed.pixelsPerPulse,
                dryRun: true,
                elapsedMilliseconds: 0
            )
            try output.success(command: "scroll", result: result)
            return
        }

        let controller = AutoScrollPulseController()
        var emittedPulses = 0
        for index in 0..<totalPulses {
            try Task.checkCancellation()
            do {
                try controller.postPulse(
                    target: target,
                    direction: options.direction,
                    speed: options.speed
                )
            } catch AutoScrollPulseControllerError.targetLeaseInvalid {
                throw CLIExecutionFailure(
                    exitCode: 75,
                    body: CLIErrorBody(
                        code: "target_changed",
                        message:
                            "Foreground application, focused window, or pointer lease changed after \(emittedPulses) pulses.",
                        hint: "Refocus the intended window, place the pointer inside it, and retry."
                    )
                )
            }
            emittedPulses += 1
            if emitEvents,
                emittedPulses == 1 || emittedPulses == totalPulses || emittedPulses % 10 == 0
            {
                output.event(
                    command: "scroll",
                    event: ScrollProgressEvent(
                        phase: "scrolling",
                        emittedPulses: emittedPulses,
                        totalPulses: totalPulses
                    )
                )
            }
            if index + 1 < totalPulses {
                try await Task.sleep(for: pulseInterval(for: options.speed))
            }
        }

        let elapsed = start.duration(to: .now)
        let result = ScrollResult(
            target: TargetResult(target: target),
            direction: options.direction.rawValue,
            speed: options.speed.rawValue,
            emittedPulses: emittedPulses,
            pixelsPerPulse: options.speed.pixelsPerPulse,
            dryRun: false,
            elapsedMilliseconds: durationMilliseconds(elapsed)
        )
        try output.success(command: "scroll", result: result)
    }

    private static func runLongshot(
        _ options: LongshotOptions,
        emitEvents: Bool,
        output: CLIOutput
    ) async throws {
        let outputURL = try resolvedOutputURL(options.outputPath)
        try validateOutputURL(outputURL, overwrite: options.overwrite)
        let bundleIdentifier =
            if options.bundleIdentifier != nil || options.windowID != nil {
                options.bundleIdentifier
            } else {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        guard bundleIdentifier != nil || options.windowID != nil else {
            throw CLIExecutionFailure(
                exitCode: 69,
                body: CLIErrorBody(
                    code: "target_application_unavailable",
                    message: "No explicit window ID was provided and the frontmost app has no bundle identifier.",
                    hint: "Run 'longview windows' and pass --window-id."
                )
            )
        }
        let target = try await WindowTargetResolver().resolve(
            WindowTargetSelector(
                bundleIdentifier: bundleIdentifier,
                windowID: options.windowID
            ))

        let coordinator = LongScreenshotCoordinator()
        let captured = try await coordinator.capture(
            target: target,
            configuration: LongScreenshotConfiguration(
                frameCount: options.frameCount,
                pulsesPerStep: options.pulsesPerStep,
                direction: options.direction,
                focusPolicy: options.focusPolicy,
                region: options.region,
                normalizedScrollPoint: options.normalizedScrollPoint,
                settleMilliseconds: options.settleMilliseconds,
                stopAtEnd: options.stopAtEnd
            )
        ) { phase in
            guard emitEvents else { return }
            output.event(command: "longshot", event: progressEvent(for: phase))
        }
        try writeAtomically(
            captured.image,
            to: outputURL,
            overwrite: options.overwrite
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let result = LongshotResult(
            target: TargetResult(target: captured.target),
            outputPath: outputURL.path,
            byteCount: byteCount,
            pixelWidth: captured.image.width,
            pixelHeight: captured.image.height,
            capturedFrameCount: captured.capturedFrameCount,
            detectedOverlaps: captured.overlaps,
            captureRegion: TargetResult.Frame(
                x: captured.regionInPixels.minX,
                y: captured.regionInPixels.minY,
                width: captured.regionInPixels.width,
                height: captured.regionInPixels.height
            ),
            scrollRoute: captured.scrollRoute.rawValue,
            stopReason: captured.stopReason.rawValue,
            targetWasActivated: captured.targetWasActivated,
            pointerWasMoved: captured.pointerWasMoved,
            viewportRestorationAttempted: captured.viewportRestorationAttempted,
            viewportRestorationSucceeded: captured.viewportRestorationSucceeded,
            environmentRestorationSucceeded: captured.environmentRestorationSucceeded
        )
        try output.success(command: "longshot", result: result)
    }

    private static func validateTarget(
        _ target: AutoScrollTarget,
        expectedBundleIdentifier: String?
    ) throws {
        guard let expectedBundleIdentifier else { return }
        guard target.bundleIdentifier == expectedBundleIdentifier else {
            throw CLIExecutionFailure(
                exitCode: 69,
                body: CLIErrorBody(
                    code: "target_mismatch",
                    message:
                        "Resolved bundle identifier '\(target.bundleIdentifier ?? "null")' does not match '\(expectedBundleIdentifier)'.",
                    hint: "Refocus the expected application before retrying."
                )
            )
        }
    }

    private static func pulseCount(for options: ScrollOptions) -> Int {
        switch options.limit {
        case .pulses(let count):
            count
        case .duration(let seconds):
            min(100_000, max(1, Int(ceil(seconds / options.speed.interval))))
        }
    }

    private static func pulseInterval(for speed: AutoScrollSpeed) -> Duration {
        .milliseconds(Int64((speed.interval * 1_000).rounded()))
    }

    private static func durationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds * 1_000
        let milliseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(seconds + milliseconds)
    }

    private static func progressEvent(for phase: LongScreenshotPhase) -> LongshotProgressEvent {
        switch phase {
        case .resolvingTarget:
            LongshotProgressEvent(
                phase: "resolving_target",
                route: nil,
                current: nil,
                total: nil
            )
        case .preparing:
            LongshotProgressEvent(
                phase: "preparing",
                route: nil,
                current: nil,
                total: nil
            )
        case .probingRoute(let route):
            LongshotProgressEvent(
                phase: "probing_route",
                route: route.rawValue,
                current: nil,
                total: nil
            )
        case .capturing(let current, let total):
            LongshotProgressEvent(
                phase: "capturing",
                route: nil,
                current: current,
                total: total
            )
        case .restoringViewport:
            LongshotProgressEvent(
                phase: "restoring_viewport",
                route: nil,
                current: nil,
                total: nil
            )
        case .restoringEnvironment:
            LongshotProgressEvent(
                phase: "restoring_environment",
                route: nil,
                current: nil,
                total: nil
            )
        case .stitching:
            LongshotProgressEvent(
                phase: "stitching",
                route: nil,
                current: nil,
                total: nil
            )
        }
    }

    private static func resolvedOutputURL(_ path: String) throws -> URL {
        guard path != "-" else {
            throw CLIExecutionFailure(
                exitCode: 64,
                body: CLIErrorBody(
                    code: "invalid_output",
                    message: "PNG output cannot be written to stdout because stdout is reserved for JSON."
                )
            )
        }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }
        let resolved = url.standardizedFileURL
        guard resolved.pathExtension.lowercased() == "png" else {
            throw CLIExecutionFailure(
                exitCode: 64,
                body: CLIErrorBody(
                    code: "invalid_output_extension",
                    message: "Long screenshot output must use the .png extension."
                )
            )
        }
        return resolved
    }

    private static func validateOutputURL(_ url: URL, overwrite: Bool) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CLIExecutionFailure(
                exitCode: 73,
                body: CLIErrorBody(
                    code: "output_is_symbolic_link",
                    message: "Refusing to write through a symbolic link: \(url.path)"
                )
            )
        }
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CLIExecutionFailure(
                exitCode: 73,
                body: CLIErrorBody(
                    code: "output_directory_missing",
                    message: "Output directory does not exist: \(parent.path)"
                )
            )
        }
        var outputIsDirectory: ObjCBool = false
        let outputExists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &outputIsDirectory
        )
        if outputExists, outputIsDirectory.boolValue {
            throw CLIExecutionFailure(
                exitCode: 73,
                body: CLIErrorBody(
                    code: "output_is_directory",
                    message: "Output path is a directory: \(url.path)"
                )
            )
        }
        if outputExists, !overwrite {
            throw CLIExecutionFailure(
                exitCode: 73,
                body: CLIErrorBody(
                    code: "output_exists",
                    message: "Output already exists: \(url.path)",
                    hint: "Choose another path or pass --force."
                )
            )
        }
    }

    private static func writeAtomically(
        _ image: CGImage,
        to outputURL: URL,
        overwrite: Bool
    ) throws {
        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.png"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try LongScreenshotPNGWriter.write(image, to: temporaryURL)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            guard overwrite else {
                throw CLIExecutionFailure(
                    exitCode: 73,
                    body: CLIErrorBody(
                        code: "output_exists",
                        message: "Output was created before the screenshot could be committed: \(outputURL.path)",
                        hint: "Choose another path or pass --force."
                    )
                )
            }
            _ = try FileManager.default.replaceItemAt(
                outputURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    private static func map(_ error: Error) -> CLIExecutionFailure {
        if let resolverError = error as? ForegroundScrollTargetResolverError {
            switch resolverError {
            case .accessibilityPermissionMissing:
                return CLIExecutionFailure(
                    exitCode: 77,
                    body: CLIErrorBody(
                        code: "accessibility_permission_missing",
                        message: "Accessibility permission is required for target validation and scroll events.",
                        hint:
                            "Grant permission to the terminal or agent host running this CLI in System Settings > Privacy & Security > Accessibility."
                    )
                )
            case .pointerOutsideFocusedWindow:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "pointer_outside_target",
                        message: "Pointer is outside the focused foreground window.",
                        hint: "Place the pointer inside the intended scroll region and retry."
                    )
                )
            case .frontmostApplicationUnavailable, .focusedWindowUnavailable,
                .pointerLocationUnavailable, .excludedApplication:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "target_unavailable",
                        message: "A safe foreground scroll target could not be resolved: \(resolverError)."
                    )
                )
            }
        }
        if let captureError = error as? LongScreenshotError {
            switch captureError {
            case .accessibilityPermissionMissing:
                return CLIExecutionFailure(
                    exitCode: 77,
                    body: CLIErrorBody(
                        code: "accessibility_permission_missing",
                        message: "Accessibility permission is required for multi-frame longshot scroll routes.",
                        hint:
                            "Grant permission to the terminal or agent host running this CLI in System Settings > Privacy & Security > Accessibility."
                    )
                )
            case .screenCapturePermissionMissing:
                return CLIExecutionFailure(
                    exitCode: 77,
                    body: CLIErrorBody(
                        code: "screen_capture_permission_missing",
                        message: "Screen Recording permission is required for longshot.",
                        hint:
                            "Grant permission to the terminal or agent host running this CLI in System Settings > Privacy & Security > Screen & System Audio Recording."
                    )
                )
            case .unsupportedApplication:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "profile_unavailable",
                        message: "No app-specific crop profile exists for the selected application.",
                        hint: "Use --region auto, --region full, or an explicit normalized rectangle."
                    )
                )
            case .targetApplicationUnavailable:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "target_application_unavailable",
                        message: "No shareable window exists for the requested application."
                    )
                )
            case .targetWindowUnavailable, .captureWindowUnavailable:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "target_window_unavailable",
                        message: "The requested window is no longer available for capture.",
                        hint: "Run 'longview windows --bundle-id ID' and select a current window ID."
                    )
                )
            case .targetWindowAmbiguous(let ids):
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "target_window_ambiguous",
                        message: "More than one target window matched: \(ids).",
                        hint: "Pass --window-id explicitly."
                    )
                )
            case .backgroundScrollUnavailable:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "background_scroll_unavailable",
                        message: "Public background scroll routes produced no verifiable viewport movement.",
                        hint:
                            "Retry with --focus-policy background-first to permit temporary activation and automatic restoration."
                    )
                )
            case .foregroundRequired:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "foreground_required",
                        message: "The target is not frontmost and --focus-policy foreground forbids activation."
                    )
                )
            case .foregroundActivationFailed:
                return CLIExecutionFailure(
                    exitCode: 75,
                    body: CLIErrorBody(
                        code: "foreground_activation_failed",
                        message: "Temporary foreground fallback could not acquire the requested window safely."
                    )
                )
            case .foregroundWindowUnavailable:
                return CLIExecutionFailure(
                    exitCode: 69,
                    body: CLIErrorBody(
                        code: "foreground_window_unavailable",
                        message:
                            "The requested window is not visible on the active macOS Space, so foreground fallback was refused before changing focus.",
                        hint:
                            "Move the target window to the active Space, or use an app that exposes a background Accessibility scroll value."
                    )
                )
            case .targetChanged:
                return CLIExecutionFailure(
                    exitCode: 75,
                    body: CLIErrorBody(
                        code: "target_changed",
                        message: "The selected process or window changed during longshot."
                    )
                )
            default:
                return CLIExecutionFailure(
                    exitCode: 74,
                    body: CLIErrorBody(
                        code: "capture_failed",
                        message: "Long screenshot failed: \(captureError)."
                    )
                )
            }
        }
        if let postingError = error as? SystemScrollEventPosterError,
            postingError == .accessibilityPermissionMissing
        {
            return CLIExecutionFailure(
                exitCode: 77,
                body: CLIErrorBody(
                    code: "accessibility_permission_missing",
                    message: "Accessibility permission was revoked before the scroll event could be emitted."
                )
            )
        }
        return CLIExecutionFailure(
            exitCode: 74,
            body: CLIErrorBody(code: "operation_failed", message: String(describing: error))
        )
    }

    private static func usageError(_ error: Error) -> CLIErrorBody {
        let detail: String
        switch error as? CLIUsageError {
        case .missingCommand:
            detail = "Missing command."
        case .unknownCommand(let value):
            detail = "Unknown command: \(value)."
        case .unknownOption(let value):
            detail = "Unknown option: \(value)."
        case .missingValue(let option):
            detail = "Missing value for \(option)."
        case .invalidValue(let option, let value):
            detail = "Invalid value '\(value)' for \(option)."
        case .conflictingOptions(let lhs, let rhs):
            detail = "Options \(lhs) and \(rhs) cannot be used together."
        case .missingRequiredOption(let option):
            detail = "Missing required option: \(option)."
        case .unexpectedArgument(let value):
            detail = "Unexpected argument: \(value)."
        case nil:
            detail = String(describing: error)
        }
        return CLIErrorBody(
            code: "usage_error",
            message: detail,
            hint: "Run 'longview help' for the command contract."
        )
    }

    private static func inferredCommand(from arguments: [String]) -> String {
        arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "unknown"
    }

    private static let helpText = """
        longview \(LongviewBuildInfo.version)

        A UI-free, agent-friendly macOS scroll and long-screenshot CLI.

        USAGE
          longview [--json] [--pretty] [--events] <command> [options]

        COMMANDS
          capabilities
              Report permissions, supported commands, and mutation boundary.

          doctor
              Diagnose installation, platform, and permission readiness without prompting.

          windows [--bundle-id ID] [--include-titles]
              List capturable windows and stable WindowServer IDs without activating them.
              Titles are redacted unless explicitly requested.

          target
              Resolve the foreground application/window under the pointer.

          scroll [--direction up|down] [--speed slow|normal|fast]
                 [--pulses 1...100000 | --duration 0.05...3600]
                 [--expect-bundle-id ID] [--dry-run]
              Emit bounded vertical pixel-wheel pulses. Defaults to one pulse.

          longshot --output PATH.png [--bundle-id ID] [--window-id ID]
                   [--max-frames 1...100] [--pulses-per-step 1...240]
                   [--direction up|down]
                   [--focus-policy background-only|background-first|foreground]
                   [--region auto|full|profile|x,y,width,height]
                   [--scroll-point x,y] [--settle-ms 100...5000]
                   [--no-stop-at-end] [--force]
              Capture and stitch any shareable macOS window. Background routes are
              tried first by default; temporary activation is restored automatically.

          version
          help

        OUTPUT
          Success: one JSON object on stdout.
          Failure: one JSON object on stderr plus a non-zero exit code.
          --events: NDJSON progress objects on stdout, followed by the result.
          --pretty: pretty-print JSON (intended for inspection, not NDJSON parsing).

        EXIT CODES
          0 success, 64 usage, 69 unavailable/target mismatch,
          73 output creation refused, 74 I/O/capture failure,
          75 target changed, 77 permission missing, 130 canceled.
        """
}
