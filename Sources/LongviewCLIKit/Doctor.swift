import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

public struct DoctorResult: Codable, Equatable, Sendable {
    public struct Environment: Codable, Equatable, Sendable {
        public let macOSVersion: String
        public let minimumMacOSVersion: String
        public let architecture: String
        public let runningUnderRosetta: Bool
    }

    public struct Installation: Codable, Equatable, Sendable {
        public let executablePath: String
        public let managed: Bool
        public let receiptPath: String?
        public let receiptVersion: String?
        public let receiptMatchesVersion: Bool?
        public let receiptMatchesBinary: Bool?
    }

    public struct Readiness: Codable, Equatable, Sendable {
        public let windowListing: Bool
        public let singleFrameLongshot: Bool
        public let multiFrameLongshot: Bool
        public let foregroundScroll: Bool
    }

    public struct Check: Codable, Equatable, Sendable {
        public let id: String
        public let status: String
        public let message: String
        public let hint: String?
    }

    public let cliVersion: String
    public let schemaVersion: Int
    public let status: String
    public let environment: Environment
    public let installation: Installation
    public let permissions: PermissionResult
    public let permissionOwner: String
    public let readiness: Readiness
    public let checks: [Check]
}

struct DoctorInputs: Sendable {
    let macOSVersion: OperatingSystemVersion
    let architecture: String
    let runningUnderRosetta: Bool
    let executablePath: String
    let accessibility: Bool
    let screenCapture: Bool
    let receiptPath: String?
    let receiptVersion: String?
    let receiptMatchesBinary: Bool?
}

enum Doctor {
    static func evaluate(_ inputs: DoctorInputs) -> DoctorResult {
        let supported =
            inputs.macOSVersion.majorVersion
            >= LongviewBuildInfo.minimumMacOSMajorVersion
        let receiptMatchesVersion = inputs.receiptVersion.map {
            $0 == LongviewBuildInfo.version
        }
        let managed = inputs.receiptPath != nil && inputs.receiptVersion != nil
        let status: String
        if !supported {
            status = "unsupported"
        } else if !inputs.accessibility
            || !inputs.screenCapture
            || receiptMatchesVersion == false
            || inputs.receiptMatchesBinary == false
        {
            status = "action-required"
        } else {
            status = "ready"
        }

        var checks = [DoctorResult.Check]()
        checks.append(
            DoctorResult.Check(
                id: "macos-version",
                status: supported ? "pass" : "blocked",
                message: supported
                    ? "macOS satisfies Longview's minimum version."
                    : "Longview requires macOS \(LongviewBuildInfo.minimumMacOSMajorVersion) or newer.",
                hint: supported ? nil : "Run Longview on a supported Mac."
            ))
        checks.append(
            permissionCheck(
                id: "screen-capture-permission",
                granted: inputs.screenCapture,
                name: "Screen Recording",
                settingsPane: "Screen & System Audio Recording"
            ))
        checks.append(
            permissionCheck(
                id: "accessibility-permission",
                granted: inputs.accessibility,
                name: "Accessibility",
                settingsPane: "Accessibility"
            ))
        checks.append(
            DoctorResult.Check(
                id: "installation",
                status: managed ? "pass" : "info",
                message: managed
                    ? "Longview is managed by its source installer."
                    : "Longview is running from an unmanaged path or build directory.",
                hint: managed ? nil : "Run ./scripts/install.sh for a managed installation."
            ))
        if let receiptMatchesVersion, !receiptMatchesVersion {
            checks.append(
                DoctorResult.Check(
                    id: "installation-receipt-version",
                    status: "blocked",
                    message: "The installation receipt version does not match this binary.",
                    hint: "Reinstall Longview from a trusted checkout."
                ))
        }
        if inputs.receiptMatchesBinary == false {
            checks.append(
                DoctorResult.Check(
                    id: "installation-receipt-sha256",
                    status: "blocked",
                    message: "The installed binary does not match its installation receipt.",
                    hint: "Reinstall Longview from a trusted checkout."
                ))
        }

        return DoctorResult(
            cliVersion: LongviewBuildInfo.version,
            schemaVersion: CLIProtocol.schemaVersion,
            status: status,
            environment: DoctorResult.Environment(
                macOSVersion: versionString(inputs.macOSVersion),
                minimumMacOSVersion: "\(LongviewBuildInfo.minimumMacOSMajorVersion).0",
                architecture: inputs.architecture,
                runningUnderRosetta: inputs.runningUnderRosetta
            ),
            installation: DoctorResult.Installation(
                executablePath: inputs.executablePath,
                managed: managed,
                receiptPath: inputs.receiptPath,
                receiptVersion: inputs.receiptVersion,
                receiptMatchesVersion: receiptMatchesVersion,
                receiptMatchesBinary: inputs.receiptMatchesBinary
            ),
            permissions: PermissionResult(
                accessibility: inputs.accessibility,
                screenCapture: inputs.screenCapture
            ),
            permissionOwner: "invoking-terminal-or-agent-host",
            readiness: DoctorResult.Readiness(
                windowListing: supported && inputs.screenCapture,
                singleFrameLongshot: supported && inputs.screenCapture,
                multiFrameLongshot: supported && inputs.screenCapture && inputs.accessibility,
                foregroundScroll: supported && inputs.accessibility
            ),
            checks: checks
        )
    }

    @MainActor
    static func inspect() -> DoctorResult {
        let executableURL = resolvedExecutableURL()
        let receipt = installationReceipt(for: executableURL)
        return evaluate(
            DoctorInputs(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
                architecture: architecture,
                runningUnderRosetta: runningUnderRosetta,
                executablePath: executableURL.path,
                accessibility: AXIsProcessTrusted(),
                screenCapture: CGPreflightScreenCaptureAccess(),
                receiptPath: receipt?.url.path,
                receiptVersion: receipt?.version,
                receiptMatchesBinary: receipt.map {
                    sha256(of: executableURL) == $0.sha256
                }
            ))
    }

    private static func permissionCheck(
        id: String,
        granted: Bool,
        name: String,
        settingsPane: String
    ) -> DoctorResult.Check {
        DoctorResult.Check(
            id: id,
            status: granted ? "pass" : "blocked",
            message: granted ? "\(name) permission is granted." : "\(name) permission is not granted.",
            hint: granted
                ? nil
                : "Grant it to the Terminal or agent host invoking Longview in System Settings > Privacy & Security > \(settingsPane)."
        )
    }

    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static var runningUnderRosetta: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0
            && value == 1
    }

    private static func resolvedExecutableURL() -> URL {
        let argument = CommandLine.arguments.first ?? "longview"
        let url =
            argument.hasPrefix("/")
            ? URL(fileURLWithPath: argument)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argument)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct Receipt: Decodable {
        let product: String
        let version: String
        let executablePath: String
        let sha256: String
    }

    private static func installationReceipt(
        for executableURL: URL
    ) -> (url: URL, version: String, sha256: String)? {
        let binDirectory = executableURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        let receiptURL = binDirectory.deletingLastPathComponent()
            .appendingPathComponent("share/longview/install-receipt.json")
        guard let data = try? Data(contentsOf: receiptURL),
            let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
            receipt.product == "longview",
            URL(fileURLWithPath: receipt.executablePath).standardizedFileURL
                == executableURL.standardizedFileURL
        else { return nil }
        return (receiptURL, receipt.version, receipt.sha256)
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
