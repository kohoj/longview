import Foundation
import Testing

@testable import LongviewCLIKit

@Suite("Doctor readiness")
struct DoctorTests {
    @Test("missing permissions are diagnostic state, not execution failure")
    func missingPermissions() {
        let result = Doctor.evaluate(
            DoctorInputs(
                macOSVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
                architecture: "arm64",
                runningUnderRosetta: false,
                executablePath: "/tmp/longview",
                accessibility: false,
                screenCapture: false,
                receiptPath: nil,
                receiptVersion: nil,
                receiptMatchesBinary: nil
            ))

        #expect(result.status == "action-required")
        #expect(!result.readiness.windowListing)
        #expect(!result.readiness.multiFrameLongshot)
        #expect(result.checks.contains { $0.id == "screen-capture-permission" && $0.status == "blocked" })
    }

    @Test("all capabilities become ready only when both permissions exist")
    func ready() {
        let result = Doctor.evaluate(
            DoctorInputs(
                macOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0),
                architecture: "x86_64",
                runningUnderRosetta: false,
                executablePath: "/Users/test/.local/bin/longview",
                accessibility: true,
                screenCapture: true,
                receiptPath: "/Users/test/.local/share/longview/install-receipt.json",
                receiptVersion: LongviewBuildInfo.version,
                receiptMatchesBinary: true
            ))

        #expect(result.status == "ready")
        #expect(result.installation.managed)
        #expect(result.installation.receiptMatchesVersion == true)
        #expect(result.installation.receiptMatchesBinary == true)
        #expect(result.readiness.windowListing)
        #expect(result.readiness.multiFrameLongshot)
        #expect(result.readiness.foregroundScroll)
    }

    @Test("unsupported macOS is explicit")
    func unsupportedSystem() {
        let result = Doctor.evaluate(
            DoctorInputs(
                macOSVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0),
                architecture: "arm64",
                runningUnderRosetta: false,
                executablePath: "/tmp/longview",
                accessibility: true,
                screenCapture: true,
                receiptPath: nil,
                receiptVersion: nil,
                receiptMatchesBinary: nil
            ))

        #expect(result.status == "unsupported")
        #expect(!result.readiness.foregroundScroll)
    }
}
