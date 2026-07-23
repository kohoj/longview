import CoreGraphics
import LongviewCLIKit
import LongviewCore
import Testing

@Suite("CLI argument contract")
struct CLIArgumentParserTests {
    @Test("doctor is read-only and accepts no command arguments")
    func doctorCommand() throws {
        let invocation = try CLIArgumentParser.parse(["longview", "doctor", "--pretty"])
        #expect(invocation.command == .doctor)
        #expect(invocation.globalOptions.prettyPrinted)
    }

    @Test("window titles require explicit opt-in")
    func windowTitlePrivacy() throws {
        let defaults = try CLIArgumentParser.parse(["longview", "windows"])
        #expect(defaults.command == .windows(WindowListOptions()))

        let explicit = try CLIArgumentParser.parse([
            "longview", "windows", "--bundle-id", "com.apple.Safari", "--include-titles",
        ])
        #expect(
            explicit.command
                == .windows(
                    WindowListOptions(
                        bundleIdentifier: "com.apple.Safari",
                        includeTitles: true
                    )))
    }

    @Test("scroll defaults are bounded and machine-safe")
    func scrollDefaults() throws {
        let invocation = try CLIArgumentParser.parse(["longview", "scroll"])
        #expect(invocation.command == .scroll(ScrollOptions()))
    }

    @Test("global options can appear after command options")
    func globalOptionPlacement() throws {
        let invocation = try CLIArgumentParser.parse([
            "longview", "scroll", "--direction", "up", "--events",
            "--speed", "fast", "--pulses", "12", "--expect-bundle-id",
            "com.tencent.xinWeChat",
        ])
        #expect(invocation.globalOptions.emitEvents)
        #expect(
            invocation.command
                == .scroll(
                    ScrollOptions(
                        direction: .up,
                        speed: .fast,
                        limit: .pulses(12),
                        expectedBundleIdentifier: "com.tencent.xinWeChat"
                    )))
    }

    @Test("duration and pulses are mutually exclusive")
    func conflictingLimits() {
        #expect(throws: CLIUsageError.conflictingOptions("--pulses", "--duration")) {
            try CLIArgumentParser.parse([
                "longview", "scroll", "--pulses", "4", "--duration", "2",
            ])
        }
    }

    @Test("longshot requires explicit output")
    func longshotOutputRequired() {
        #expect(throws: CLIUsageError.missingRequiredOption("--output")) {
            try CLIArgumentParser.parse(["longview", "longshot"])
        }
    }

    @Test("longshot parses deterministic target and overwrite options")
    func longshotOptions() throws {
        let invocation = try CLIArgumentParser.parse([
            "longview", "longshot", "--output", "/tmp/chat.png",
            "--max-frames", "9", "--pulses-per-step", "20", "--force",
        ])
        #expect(
            invocation.command
                == .longshot(
                    LongshotOptions(
                        outputPath: "/tmp/chat.png",
                        frameCount: 9,
                        pulsesPerStep: 20,
                        overwrite: true
                    )))
    }

    @Test("generic longshot target and background policy parse deterministically")
    func genericLongshotOptions() throws {
        let invocation = try CLIArgumentParser.parse([
            "longview", "longshot", "--output", "/tmp/page.png",
            "--bundle-id", "com.apple.Safari", "--window-id", "42",
            "--max-frames", "30", "--direction", "down",
            "--focus-policy", "background-only", "--region", "0.2,0.1,0.7,0.8",
            "--scroll-point", "0.7,0.5", "--settle-ms", "700",
        ])
        #expect(
            invocation.command
                == .longshot(
                    LongshotOptions(
                        outputPath: "/tmp/page.png",
                        bundleIdentifier: "com.apple.Safari",
                        windowID: 42,
                        frameCount: 30,
                        direction: .down,
                        focusPolicy: .backgroundOnly,
                        region: .normalized(CGRect(x: 0.2, y: 0.1, width: 0.7, height: 0.8)),
                        normalizedScrollPoint: CGPoint(x: 0.7, y: 0.5),
                        settleMilliseconds: 700
                    )))
    }

    @Test("window ID is an independent target selector")
    func windowOnlyLongshotTarget() throws {
        let invocation = try CLIArgumentParser.parse([
            "longview", "longshot", "--output", "/tmp/window.png",
            "--window-id", "42",
        ])
        #expect(
            invocation.command
                == .longshot(
                    LongshotOptions(
                        outputPath: "/tmp/window.png",
                        windowID: 42
                    )))
    }

    @Test("invalid enums fail closed")
    func invalidDirection() {
        #expect(throws: CLIUsageError.invalidValue(option: "--direction", value: "sideways")) {
            try CLIArgumentParser.parse([
                "longview", "scroll", "--direction", "sideways",
            ])
        }
    }

    @Test("pretty JSON and NDJSON events cannot be combined")
    func incompatibleOutputModes() {
        #expect(throws: CLIUsageError.conflictingOptions("--pretty", "--events")) {
            try CLIArgumentParser.parse([
                "longview", "capabilities", "--pretty", "--events",
            ])
        }
    }
}
