import XCTest

@testable import LongviewCapture

final class AdaptiveCapturePacerTests: XCTestCase {
    func testIncreasesPulsesWhenOverlapIsAbundant() {
        var pacer = AdaptiveCapturePacer(initialPulsesPerStep: 28)

        pacer.observe(overlap: 561, viewportHeight: 757)

        XCTAssertEqual(pacer.pulsesPerStep, 45)
    }

    func testBacksOffBeforeMinimumOverlapIsThreatened() {
        var pacer = AdaptiveCapturePacer(initialPulsesPerStep: 100)

        pacer.observe(overlap: 150, viewportHeight: 757)

        XCTAssertEqual(pacer.pulsesPerStep, 65)
    }

    func testNeverExceedsConfiguredMaximum() {
        var pacer = AdaptiveCapturePacer(
            initialPulsesPerStep: 200,
            maximumPulsesPerStep: 240
        )

        pacer.observe(overlap: 700, viewportHeight: 757)

        XCTAssertEqual(pacer.pulsesPerStep, 240)
    }

    func testIgnoresInvalidObservation() {
        var pacer = AdaptiveCapturePacer(initialPulsesPerStep: 28)

        pacer.observe(overlap: 757, viewportHeight: 757)

        XCTAssertEqual(pacer.pulsesPerStep, 28)
    }
}
