import CoreGraphics
import Foundation
import LongviewCapture
import LongviewCore

public enum CLIUsageError: Error, Equatable, Sendable {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case conflictingOptions(String, String)
    case missingRequiredOption(String)
    case unexpectedArgument(String)
}

public struct CLIGlobalOptions: Equatable, Sendable {
    public var prettyPrinted = false
    public var emitEvents = false

    public init(prettyPrinted: Bool = false, emitEvents: Bool = false) {
        self.prettyPrinted = prettyPrinted
        self.emitEvents = emitEvents
    }
}

public struct ScrollOptions: Equatable, Sendable {
    public enum Limit: Equatable, Sendable {
        case pulses(Int)
        case duration(TimeInterval)
    }

    public var direction: AutoScrollDirection
    public var speed: AutoScrollSpeed
    public var limit: Limit
    public var expectedBundleIdentifier: String?
    public var dryRun: Bool

    public init(
        direction: AutoScrollDirection = .down,
        speed: AutoScrollSpeed = .normal,
        limit: Limit = .pulses(1),
        expectedBundleIdentifier: String? = nil,
        dryRun: Bool = false
    ) {
        self.direction = direction
        self.speed = speed
        self.limit = limit
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.dryRun = dryRun
    }
}

public struct LongshotOptions: Equatable, Sendable {
    public var outputPath: String
    public var bundleIdentifier: String?
    public var windowID: UInt32?
    public var frameCount: Int
    public var pulsesPerStep: Int
    public var direction: LongScreenshotDirection
    public var focusPolicy: LongScreenshotFocusPolicy
    public var region: LongScreenshotRegion
    public var normalizedScrollPoint: CGPoint
    public var settleMilliseconds: Int
    public var stopAtEnd: Bool
    public var overwrite: Bool

    public init(
        outputPath: String,
        bundleIdentifier: String? = nil,
        windowID: UInt32? = nil,
        frameCount: Int = 6,
        pulsesPerStep: Int = 28,
        direction: LongScreenshotDirection = .up,
        focusPolicy: LongScreenshotFocusPolicy = .backgroundFirst,
        region: LongScreenshotRegion = .automatic,
        normalizedScrollPoint: CGPoint = CGPoint(x: 0.65, y: 0.5),
        settleMilliseconds: Int = 450,
        stopAtEnd: Bool = true,
        overwrite: Bool = false
    ) {
        self.outputPath = outputPath
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.frameCount = frameCount
        self.pulsesPerStep = pulsesPerStep
        self.direction = direction
        self.focusPolicy = focusPolicy
        self.region = region
        self.normalizedScrollPoint = normalizedScrollPoint
        self.settleMilliseconds = settleMilliseconds
        self.stopAtEnd = stopAtEnd
        self.overwrite = overwrite
    }
}

public struct WindowListOptions: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var includeTitles: Bool

    public init(bundleIdentifier: String? = nil, includeTitles: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.includeTitles = includeTitles
    }
}

public enum CLICommand: Equatable, Sendable {
    case capabilities
    case doctor
    case windows(WindowListOptions)
    case target
    case scroll(ScrollOptions)
    case longshot(LongshotOptions)
    case version
    case help

    public var name: String {
        switch self {
        case .capabilities: "capabilities"
        case .doctor: "doctor"
        case .windows: "windows"
        case .target: "target"
        case .scroll: "scroll"
        case .longshot: "longshot"
        case .version: "version"
        case .help: "help"
        }
    }
}

public struct CLIInvocation: Equatable, Sendable {
    public let command: CLICommand
    public let globalOptions: CLIGlobalOptions

    public init(command: CLICommand, globalOptions: CLIGlobalOptions) {
        self.command = command
        self.globalOptions = globalOptions
    }
}

public enum CLIArgumentParser {
    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var tokens = Array(arguments.dropFirst())
        var globalOptions = CLIGlobalOptions()
        tokens.removeAll { token in
            switch token {
            case "--pretty":
                globalOptions.prettyPrinted = true
                return true
            case "--events":
                globalOptions.emitEvents = true
                return true
            case "--json":
                return true
            default:
                return false
            }
        }

        if globalOptions.prettyPrinted, globalOptions.emitEvents {
            throw CLIUsageError.conflictingOptions("--pretty", "--events")
        }

        guard let commandName = tokens.first else {
            throw CLIUsageError.missingCommand
        }
        tokens.removeFirst()

        let command: CLICommand
        switch commandName {
        case "capabilities":
            try requireNoArguments(tokens)
            command = .capabilities
        case "doctor":
            try requireNoArguments(tokens)
            command = .doctor
        case "windows":
            command = .windows(try parseWindows(tokens))
        case "target":
            try requireNoArguments(tokens)
            command = .target
        case "scroll":
            command = .scroll(try parseScroll(tokens))
        case "longshot":
            command = .longshot(try parseLongshot(tokens))
        case "version", "--version", "-V":
            try requireNoArguments(tokens)
            command = .version
        case "help", "--help", "-h":
            try requireNoArguments(tokens)
            command = .help
        default:
            throw CLIUsageError.unknownCommand(commandName)
        }
        return CLIInvocation(command: command, globalOptions: globalOptions)
    }

    private static func parseScroll(_ tokens: [String]) throws -> ScrollOptions {
        var options = ScrollOptions()
        var explicitPulses: Int?
        var duration: TimeInterval?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--direction":
                let value = try value(after: token, in: tokens, index: &index)
                guard let direction = AutoScrollDirection(rawValue: value) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                options.direction = direction
            case "--speed":
                let value = try value(after: token, in: tokens, index: &index)
                guard let speed = AutoScrollSpeed(rawValue: value) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                options.speed = speed
            case "--pulses":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = Int(value), (1...100_000).contains(parsed) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                explicitPulses = parsed
            case "--duration":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = TimeInterval(value), (0.05...3_600).contains(parsed) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                duration = parsed
            case "--expect-bundle-id":
                let value = try value(after: token, in: tokens, index: &index)
                guard !value.isEmpty else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                options.expectedBundleIdentifier = value
            case "--dry-run":
                options.dryRun = true
            default:
                throw token.hasPrefix("-")
                    ? CLIUsageError.unknownOption(token)
                    : CLIUsageError.unexpectedArgument(token)
            }
            index += 1
        }
        if explicitPulses != nil, duration != nil {
            throw CLIUsageError.conflictingOptions("--pulses", "--duration")
        }
        if let explicitPulses {
            options.limit = .pulses(explicitPulses)
        } else if let duration {
            options.limit = .duration(duration)
        }
        return options
    }

    private static func parseLongshot(_ tokens: [String]) throws -> LongshotOptions {
        var outputPath: String?
        var bundleIdentifier: String?
        var windowID: UInt32?
        var frameCount = 6
        var pulsesPerStep = 28
        var direction = LongScreenshotDirection.up
        var focusPolicy = LongScreenshotFocusPolicy.backgroundFirst
        var region = LongScreenshotRegion.automatic
        var normalizedScrollPoint = CGPoint(x: 0.65, y: 0.5)
        var settleMilliseconds = 450
        var stopAtEnd = true
        var overwrite = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--output":
                outputPath = try value(after: token, in: tokens, index: &index)
            case "--bundle-id":
                let value = try value(after: token, in: tokens, index: &index)
                guard !value.isEmpty else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                bundleIdentifier = value
            case "--window-id":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = UInt32(value), parsed > 0 else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                windowID = parsed
            case "--max-frames":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = Int(value), (1...100).contains(parsed) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                frameCount = parsed
            case "--pulses-per-step":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = Int(value), (1...240).contains(parsed) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                pulsesPerStep = parsed
            case "--direction":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = LongScreenshotDirection(rawValue: value) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                direction = parsed
            case "--focus-policy":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = LongScreenshotFocusPolicy(rawValue: value) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                focusPolicy = parsed
            case "--region":
                let value = try value(after: token, in: tokens, index: &index)
                region = try parseRegion(value, option: token)
            case "--scroll-point":
                let value = try value(after: token, in: tokens, index: &index)
                normalizedScrollPoint = try parsePoint(value, option: token)
            case "--settle-ms":
                let value = try value(after: token, in: tokens, index: &index)
                guard let parsed = Int(value), (100...5_000).contains(parsed) else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                settleMilliseconds = parsed
            case "--no-stop-at-end":
                stopAtEnd = false
            case "--force":
                overwrite = true
            default:
                throw token.hasPrefix("-")
                    ? CLIUsageError.unknownOption(token)
                    : CLIUsageError.unexpectedArgument(token)
            }
            index += 1
        }
        guard let outputPath, !outputPath.isEmpty else {
            throw CLIUsageError.missingRequiredOption("--output")
        }
        return LongshotOptions(
            outputPath: outputPath,
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            frameCount: frameCount,
            pulsesPerStep: pulsesPerStep,
            direction: direction,
            focusPolicy: focusPolicy,
            region: region,
            normalizedScrollPoint: normalizedScrollPoint,
            settleMilliseconds: settleMilliseconds,
            stopAtEnd: stopAtEnd,
            overwrite: overwrite
        )
    }

    private static func parseWindows(_ tokens: [String]) throws -> WindowListOptions {
        var bundleIdentifier: String?
        var includeTitles = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--bundle-id":
                let value = try value(after: token, in: tokens, index: &index)
                guard !value.isEmpty else {
                    throw CLIUsageError.invalidValue(option: token, value: value)
                }
                bundleIdentifier = value
            case "--include-titles":
                includeTitles = true
            default:
                throw token.hasPrefix("-")
                    ? CLIUsageError.unknownOption(token)
                    : CLIUsageError.unexpectedArgument(token)
            }
            index += 1
        }
        return WindowListOptions(
            bundleIdentifier: bundleIdentifier,
            includeTitles: includeTitles
        )
    }

    private static func parseRegion(
        _ value: String,
        option: String
    ) throws -> LongScreenshotRegion {
        switch value {
        case "auto": return .automatic
        case "full": return .fullWindow
        case "profile": return .appProfile
        default:
            let components = value.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard components.count == 4 else {
                throw CLIUsageError.invalidValue(option: option, value: value)
            }
            let rect = CGRect(
                x: components[0],
                y: components[1],
                width: components[2],
                height: components[3]
            )
            guard rect.minX >= 0,
                rect.minY >= 0,
                rect.maxX <= 1,
                rect.maxY <= 1,
                rect.width > 0.05,
                rect.height > 0.05
            else { throw CLIUsageError.invalidValue(option: option, value: value) }
            return .normalized(rect)
        }
    }

    private static func parsePoint(
        _ value: String,
        option: String
    ) throws -> CGPoint {
        let components = value.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard components.count == 2,
            (0...1).contains(components[0]),
            (0...1).contains(components[1])
        else { throw CLIUsageError.invalidValue(option: option, value: value) }
        return CGPoint(x: components[0], y: components[1])
    }

    private static func value(
        after option: String,
        in tokens: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < tokens.count else {
            throw CLIUsageError.missingValue(option)
        }
        let value = tokens[valueIndex]
        guard !value.hasPrefix("-") else {
            throw CLIUsageError.missingValue(option)
        }
        index = valueIndex
        return value
    }

    private static func requireNoArguments(_ tokens: [String]) throws {
        guard let first = tokens.first else { return }
        throw first.hasPrefix("-")
            ? CLIUsageError.unknownOption(first)
            : CLIUsageError.unexpectedArgument(first)
    }
}
