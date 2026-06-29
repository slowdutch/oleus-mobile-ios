import Foundation

/// Main-thread hang watchdog for iOS.
///
/// Every `intervalMs` the main queue is asked to update a timestamp. If the
/// main thread has not responded within `thresholdMs` the main thread is
/// considered blocked and `onAnr` is called with a best-effort pre-hang stack
/// and the blocked duration. One report per blockage; re-arms after recovery.
///
/// Complements MetricKit `MXHangDiagnostic` (which only surfaces hangs the
/// OS measured, delivered the following day) with live, in-session detection.
final class AnrWatchdog: @unchecked Sendable {
    private let thresholdMs: Int
    private let intervalMs: Int
    private let onAnr: (_ stack: String, _ blockedForMs: Int) -> Void

    private var running = false
    private var lastTickDate = Date()
    private var reportedCurrentBlockage = false
    // Captured by the main thread on every healthy tick. Represents the
    // run-loop state just before the main thread potentially gets blocked.
    private var lastMainStack = "unavailable"

    init(
        thresholdMs: Int = 5_000,
        intervalMs: Int = 1_000,
        onAnr: @escaping (_ stack: String, _ blockedForMs: Int) -> Void
    ) {
        self.thresholdMs = thresholdMs
        self.intervalMs  = intervalMs
        self.onAnr       = onAnr
    }

    func start() {
        guard !running else { return }
        running      = true
        lastTickDate = Date()
        scheduleMainTick()
        Thread.detachNewThread { [weak self] in self?.watchLoop() }
    }

    func stop() { running = false }

    // MARK: – private

    private func scheduleMainTick() {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(intervalMs)) { [weak self] in
            guard let self, self.running else { return }
            self.lastTickDate   = Date()
            self.lastMainStack  = Thread.callStackSymbols.joined(separator: "\n")
            self.scheduleMainTick()
        }
    }

    private func watchLoop() {
        while running {
            Thread.sleep(forTimeInterval: Double(intervalMs) / 1_000)
            let blockedForMs = Int(-lastTickDate.timeIntervalSinceNow * 1_000)
            if blockedForMs > thresholdMs && !reportedCurrentBlockage {
                reportedCurrentBlockage = true
                onAnr(lastMainStack, blockedForMs)
            } else if blockedForMs < thresholdMs {
                reportedCurrentBlockage = false
            }
        }
    }
}
