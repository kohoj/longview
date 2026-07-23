import CoreGraphics
import XCTest

@testable import LongviewCore

@MainActor
final class AutoScrollEngineTests: XCTestCase {
    func testTickPostsConfiguredDelta() {
        let poster = RecordingPoster()
        let lease = StubLeaseValidator(valid: true)
        let engine = AutoScrollEngine(
            configuration: AutoScrollConfiguration(
                direction: .down,
                speed: .fast
            ),
            eventPoster: poster,
            leaseValidator: lease
        )
        let target = AutoScrollTarget(
            processIdentifier: 42,
            bundleIdentifier: "example.reader",
            applicationName: "Reader",
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        engine.start(target: target)
        engine.tickForTesting()
        engine.stop()

        XCTAssertEqual(poster.events, [PostedEvent(delta: -7)])
        XCTAssertEqual(engine.emittedPulseCount, 1)
    }

    func testChangingFrontmostApplicationStopsBeforePosting() {
        let poster = RecordingPoster()
        let lease = StubLeaseValidator(valid: true)
        let engine = AutoScrollEngine(
            eventPoster: poster,
            leaseValidator: lease
        )
        engine.start(target: target(processIdentifier: 42))
        lease.valid = false

        engine.tickForTesting()

        XCTAssertEqual(engine.state, .stopped(.frontmostApplicationChanged))
        XCTAssertNil(engine.target)
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testPausedEngineNeverPosts() {
        let poster = RecordingPoster()
        let lease = StubLeaseValidator(valid: true)
        let engine = AutoScrollEngine(
            eventPoster: poster,
            leaseValidator: lease
        )
        engine.start(target: target(processIdentifier: 42))
        engine.pause()

        engine.tickForTesting()

        XCTAssertEqual(engine.state, .paused)
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testPosterFailureStopsEngine() {
        let poster = RecordingPoster(shouldFail: true)
        let lease = StubLeaseValidator(valid: true)
        let engine = AutoScrollEngine(
            eventPoster: poster,
            leaseValidator: lease
        )
        engine.start(target: target(processIdentifier: 42))

        engine.tickForTesting()

        XCTAssertEqual(engine.state, .stopped(.eventPostingFailed))
        XCTAssertNil(engine.target)
    }

    func testStopCancelsAllFuturePulses() async throws {
        let poster = RecordingPoster()
        let engine = AutoScrollEngine(
            configuration: AutoScrollConfiguration(speed: .fast),
            eventPoster: poster,
            leaseValidator: StubLeaseValidator(valid: true)
        )
        engine.start(target: target(processIdentifier: 42))
        try await Task.sleep(for: .milliseconds(150))
        engine.stop(reason: .emergencyShortcut)
        let countAtStop = poster.events.count

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertGreaterThan(countAtStop, 0)
        XCTAssertEqual(poster.events.count, countAtStop)
        XCTAssertEqual(engine.state, .stopped(.emergencyShortcut))
    }

    private func target(processIdentifier: pid_t) -> AutoScrollTarget {
        AutoScrollTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "example.reader",
            applicationName: "Reader",
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private struct PostedEvent: Equatable {
    let delta: Int32
}

@MainActor
private final class RecordingPoster: ScrollEventPosting {
    private(set) var events: [PostedEvent] = []
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func postPixelDelta(_ delta: Int32) throws {
        if shouldFail { throw TestError.failed }
        events.append(PostedEvent(delta: delta))
    }

    private enum TestError: Error {
        case failed
    }
}

@MainActor
private final class StubLeaseValidator: ScrollTargetLeaseValidating {
    var valid: Bool

    init(valid: Bool) {
        self.valid = valid
    }

    func isValid(_ target: AutoScrollTarget) -> Bool {
        valid
    }
}
