import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
public final class AutoScrollEngine: ObservableObject {
    @Published public private(set) var state: AutoScrollState = .stopped(nil)
    @Published public private(set) var target: AutoScrollTarget?
    @Published public private(set) var emittedPulseCount = 0

    public private(set) var configuration: AutoScrollConfiguration

    private let eventPoster: any ScrollEventPosting
    private let leaseValidator: any ScrollTargetLeaseValidating
    private let pulseController: AutoScrollPulseController
    private var timer: DispatchSourceTimer?
    private var pausedAt: Date?

    public init(
        configuration: AutoScrollConfiguration = AutoScrollConfiguration(),
        eventPoster: any ScrollEventPosting = SystemScrollEventPoster(),
        leaseValidator: any ScrollTargetLeaseValidating = SystemScrollTargetLeaseValidator()
    ) {
        self.configuration = configuration
        self.eventPoster = eventPoster
        self.leaseValidator = leaseValidator
        self.pulseController = AutoScrollPulseController(
            eventPoster: eventPoster,
            leaseValidator: leaseValidator
        )
    }

    deinit {
        timer?.cancel()
    }

    public func start(target: AutoScrollTarget) {
        stopTimer()
        self.target = target
        emittedPulseCount = 0
        pausedAt = nil
        state = .running
        scheduleTimer()
    }

    public func updateConfiguration(_ configuration: AutoScrollConfiguration) {
        self.configuration = configuration
        if state == .running {
            stopTimer()
            scheduleTimer()
        }
    }

    public func pause() {
        guard state == .running else { return }
        stopTimer()
        pausedAt = Date()
        state = .paused
    }

    public func resume() {
        guard state == .paused, target != nil else { return }
        guard let pauseBeganAt = pausedAt, Date().timeIntervalSince(pauseBeganAt) <= 30 else {
            stop(reason: .pauseLeaseExpired)
            return
        }
        guard targetIsStillFrontmost else {
            stop(reason: .frontmostApplicationChanged)
            return
        }
        state = .running
        pausedAt = nil
        scheduleTimer()
    }

    public func stop(reason: AutoScrollStopReason = .userRequested) {
        stopTimer()
        target = nil
        pausedAt = nil
        state = .stopped(reason)
    }

    public func tickForTesting() {
        tick()
    }

    private var targetIsStillFrontmost: Bool {
        guard let target else { return false }
        return leaseValidator.isValid(target)
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + configuration.speed.interval,
            repeating: configuration.speed.interval,
            leeway: .milliseconds(8)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard state == .running, let target else { return }
        do {
            try pulseController.postPulse(
                target: target,
                direction: configuration.direction,
                speed: configuration.speed
            )
            emittedPulseCount += 1
        } catch AutoScrollPulseControllerError.targetLeaseInvalid {
            stop(reason: .frontmostApplicationChanged)
        } catch {
            stop(reason: .eventPostingFailed)
        }
    }
}
