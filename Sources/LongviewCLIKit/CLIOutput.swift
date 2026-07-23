import Foundation

public enum CLIProtocol {
    public static let schemaVersion = 2
}

public struct CLIErrorBody: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

private struct SuccessEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = CLIProtocol.schemaVersion
    let type = "result"
    let ok = true
    let command: String
    let result: Value
}

private struct ErrorEnvelope: Encodable {
    let schemaVersion = CLIProtocol.schemaVersion
    let type = "error"
    let ok = false
    let command: String
    let error: CLIErrorBody
}

private struct EventEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = CLIProtocol.schemaVersion
    let type = "progress"
    let command: String
    let event: Value
}

@MainActor
public final class CLIOutput {
    public typealias Write = @MainActor (Data) -> Void

    private let standardOutput: Write
    private let standardError: Write
    private let prettyPrinted: Bool

    public init(
        prettyPrinted: Bool,
        standardOutput: @escaping Write,
        standardError: @escaping Write
    ) {
        self.prettyPrinted = prettyPrinted
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static func terminal(prettyPrinted: Bool) -> CLIOutput {
        CLIOutput(
            prettyPrinted: prettyPrinted,
            standardOutput: { FileHandle.standardOutput.write($0) },
            standardError: { FileHandle.standardError.write($0) }
        )
    }

    public func success<Value: Encodable>(command: String, result: Value) throws {
        try write(SuccessEnvelope(command: command, result: result), to: standardOutput)
    }

    public func failure(command: String, error: CLIErrorBody) {
        try? write(ErrorEnvelope(command: command, error: error), to: standardError)
    }

    public func event<Value: Encodable>(command: String, event: Value) {
        try? write(EventEnvelope(command: command, event: event), to: standardOutput)
    }

    public func text(_ value: String) {
        standardOutput(Data((value + "\n").utf8))
    }

    private func write<Value: Encodable>(_ value: Value, to destination: Write) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        destination(data)
    }
}
