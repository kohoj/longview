import AppKit

private enum FixtureMode: Equatable {
    case backgroundAccessibility
    case foregroundFallback
}

@MainActor
private final class ForegroundOnlyScrollView: NSView {
    private var scrollOffset: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard NSApp.isActive else { return }
        scrollOffset = min(2_400, max(0, scrollOffset + event.scrollingDeltaY))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let firstLine = Int(scrollOffset / 20)
        let partialOffset = scrollOffset.truncatingRemainder(dividingBy: 20)
        for visibleIndex in 0..<40 {
            let line = firstLine + visibleIndex + 1
            let text = String(
                format: "%03d  foreground fallback verified by captured motion",
                line
            )
            (text as NSString).draw(
                at: NSPoint(x: 28, y: 24 + CGFloat(visibleIndex) * 20 - partialOffset),
                withAttributes: attributes
            )
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private let mode: FixtureMode
    private var window: NSWindow?

    init(mode: FixtureMode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 64, y: 96, width: 720, height: 640)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title =
            mode == .backgroundAccessibility
            ? "Longview AX Background Fixture"
            : "Longview Foreground Fallback Fixture"
        window.collectionBehavior = [.moveToActiveSpace]

        switch mode {
        case .backgroundAccessibility:
            let scrollView = NSScrollView(
                frame: NSRect(origin: .zero, size: frame.size)
            )
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
            scrollView.drawsBackground = true

            let textView = NSTextView(
                frame: NSRect(x: 0, y: 0, width: frame.width, height: 4_800)
            )
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            textView.textContainerInset = NSSize(width: 24, height: 24)
            textView.string = (1...180).map { line in
                String(format: "%03d  longview background capture fixture", line)
            }.joined(separator: "\n")
            scrollView.documentView = textView
            window.contentView = scrollView
        case .foregroundFallback:
            let view = ForegroundOnlyScrollView(
                frame: NSRect(origin: .zero, size: frame.size)
            )
            window.contentView = view
            window.makeFirstResponder(view)
        }
        window.minSize = NSSize(width: 480, height: 360)
        window.setContentSize(NSSize(width: 720, height: 640))
        window.setFrameOrigin(NSPoint(x: 64, y: 96))
        window.orderFrontRegardless()
        self.window = window

        FileHandle.standardOutput.write(
            Data("fixture-ready pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        )
    }
}

let application = NSApplication.shared
private let fixtureMode: FixtureMode =
    CommandLine.arguments.contains(
        "--foreground-fallback"
    ) ? .foregroundFallback : .backgroundAccessibility
application.setActivationPolicy(.accessory)
private let delegate = FixtureDelegate(mode: fixtureMode)
application.delegate = delegate
application.run()
