import AppKit
import Darwin
import Dispatch
import Foundation
import LongviewCLIKit

private final class SignalCancellationMonitor {
    private var sources: [DispatchSourceSignal] = []

    init(cancel: @escaping @Sendable () -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler(handler: cancel)
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }
}

@main
struct LongviewCLIExecutable {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let operation = Task { @MainActor in
            await LongviewCLI.main()
        }
        let cancellationMonitor = SignalCancellationMonitor {
            operation.cancel()
        }
        let exitCode = await operation.value
        withExtendedLifetime(cancellationMonitor) {}
        Foundation.exit(exitCode)
    }
}
