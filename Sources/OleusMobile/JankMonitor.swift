#if canImport(UIKit)
import UIKit
import QuartzCore

/// CADisplayLink-based frame-drop monitor.
///
/// Measures the elapsed time between successive display callbacks. Frames
/// that exceed `slowThresholdMs` are "slow frames"; those exceeding
/// `frozenThresholdMs` are "frozen frames". Both are reported through the
/// `onJank` callback so the SDK can ship them as ERROR-severity OTLP records.
///
/// The first tick after `start()` is skipped (no prior timestamp to diff).
final class JankMonitor {
    /// Frame took 3+ vsync periods (>50 ms at 60 Hz, >33 ms at 90/120 Hz).
    let slowThresholdMs: Double
    /// Frame took 700 ms+ — effectively a visible UI freeze.
    let frozenThresholdMs: Double

    private let onJank: (_ frameMs: Double, _ type: String) -> Void
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    init(
        slowThresholdMs: Double   = 50,
        frozenThresholdMs: Double = 700,
        onJank: @escaping (_ frameMs: Double, _ type: String) -> Void
    ) {
        self.slowThresholdMs   = slowThresholdMs
        self.frozenThresholdMs = frozenThresholdMs
        self.onJank            = onJank
    }

    func start() {
        guard displayLink == nil else { return }
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let frameMs = (link.timestamp - lastTimestamp) * 1_000
        if frameMs >= frozenThresholdMs {
            onJank(frameMs, "frozen_frame")
        } else if frameMs >= slowThresholdMs {
            onJank(frameMs, "slow_frame")
        }
    }
}
#endif
