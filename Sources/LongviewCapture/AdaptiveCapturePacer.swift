import Foundation

/// Closed-loop pacing for long screenshots.
///
/// Scroll event counts are only an input signal; captured displacement is the
/// ground truth. The pacer increases work while overlap is abundant and backs
/// off before the stitcher's minimum-overlap invariant can be threatened.
struct AdaptiveCapturePacer: Equatable {
    static let probeEventIntervalMilliseconds = 1
    static let eventIntervalMilliseconds = 1
    static let restorationEventIntervalMilliseconds = 2
    static let eventQuietFrameWindowMilliseconds = 50
    static let quietFrameWindowMilliseconds = 100
    static let routeProbeWaitMilliseconds = 180

    private static let targetOverlapFraction = 0.34
    private static let minimumOverlapFraction = 0.24
    private static let maximumIncrease = 1.6
    private static let maximumDecrease = 0.65

    private(set) var pulsesPerStep: Int
    let maximumPulsesPerStep: Int

    init(initialPulsesPerStep: Int, maximumPulsesPerStep: Int = 240) {
        pulsesPerStep = initialPulsesPerStep
        self.maximumPulsesPerStep = maximumPulsesPerStep
    }

    static func minimumSafeOverlap(viewportHeight: Int) -> Int {
        max(
            80,
            Int((Double(viewportHeight) * minimumOverlapFraction).rounded())
        )
    }

    mutating func observe(overlap: Int, viewportHeight: Int) {
        guard viewportHeight > 0,
            overlap > 0,
            overlap < viewportHeight
        else { return }

        let displacement = viewportHeight - overlap
        let targetOverlap = max(
            96,
            Int((Double(viewportHeight) * Self.targetOverlapFraction).rounded())
        )
        let minimumOverlap = Self.minimumSafeOverlap(
            viewportHeight: viewportHeight
        )
        let targetDisplacement = max(1, viewportHeight - targetOverlap)

        var scale = Double(targetDisplacement) / Double(displacement)
        if overlap <= minimumOverlap {
            scale = min(scale, Self.maximumDecrease)
        } else {
            scale = min(Self.maximumIncrease, max(Self.maximumDecrease, scale))
        }

        pulsesPerStep = min(
            maximumPulsesPerStep,
            max(1, Int((Double(pulsesPerStep) * scale).rounded()))
        )
    }
}
