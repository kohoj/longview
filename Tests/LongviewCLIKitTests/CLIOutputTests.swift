import Foundation
import LongviewCLIKit
import Testing

@Suite("CLI JSON protocol")
@MainActor
struct CLIOutputTests {
    @Test("success is one newline-terminated result object")
    func successEnvelope() throws {
        var stdout = Data()
        var stderr = Data()
        let output = CLIOutput(
            prettyPrinted: false,
            standardOutput: { stdout.append($0) },
            standardError: { stderr.append($0) }
        )

        try output.success(
            command: "version",
            result: ["version": LongviewBuildInfo.version]
        )

        #expect(stdout.last == 0x0A)
        #expect(stderr.isEmpty)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["type"] as? String == "result")
        #expect(object["ok"] as? Bool == true)
        #expect(object["command"] as? String == "version")
    }

    @Test("failure is isolated on stderr")
    func failureEnvelope() throws {
        var stdout = Data()
        var stderr = Data()
        let output = CLIOutput(
            prettyPrinted: false,
            standardOutput: { stdout.append($0) },
            standardError: { stderr.append($0) }
        )

        output.failure(
            command: "scroll",
            error: CLIErrorBody(code: "target_changed", message: "Changed.")
        )

        #expect(stdout.isEmpty)
        let object = try #require(
            JSONSerialization.jsonObject(with: stderr) as? [String: Any]
        )
        #expect(object["type"] as? String == "error")
        #expect(object["ok"] as? Bool == false)
    }
}
