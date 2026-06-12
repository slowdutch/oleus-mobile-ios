import Foundation

#if canImport(MetricKit) && os(iOS)
import MetricKit

/// Apple-blessed crash/hang cross-check. MetricKit delivers MXCrashDiagnostic
/// and MXHangDiagnostic payloads (typically on next launch, daily-batched).
/// These are shipped tagged `crash_source: metrickit` so the inbox can
/// reconcile them against the SDK's own signal/exception captures — the
/// agreed validation gate before Oleus becomes the sole crash source.
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber {
    private let config: OleusConfig
    private let events: EventQueue

    init(config: OleusConfig, events: EventQueue) {
        self.config = config
        self.events = events
        super.init()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                ship(kind: "MXCrashDiagnostic",
                     severity: "FATAL",
                     body: "MetricKit crash: signal \(crash.signal?.stringValue ?? "?") exception \(crash.exceptionType?.stringValue ?? "?")",
                     callStack: crash.callStackTree)
            }
            for hang in payload.hangDiagnostics ?? [] {
                ship(kind: "MXHangDiagnostic",
                     severity: "ERROR",
                     body: "MetricKit hang: \(hang.hangDuration)",
                     callStack: hang.callStackTree)
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var attrs = OleusOTLP.baseAttributes(config: config, sessionId: nil)
            attrs["event.name"] = "metrickit_daily"
            attrs["event.domain"] = "oleus"

            if let launch = payload.applicationLaunchMetrics {
                let (avg, max, samples) = summarize(launch.histogrammedTimeToFirstDraw)
                if samples > 0 {
                    attrs["launch_ttfd_avg_ms"] = String(format: "%.0f", avg)
                    attrs["launch_ttfd_max_ms"] = String(format: "%.0f", max)
                    attrs["launch_samples"] = String(samples)
                }
            }
            if let responsiveness = payload.applicationResponsivenessMetrics {
                let (avg, max, samples) = summarize(responsiveness.histogrammedApplicationHangTime)
                if samples > 0 {
                    attrs["hang_avg_ms"] = String(format: "%.0f", avg)
                    attrs["hang_max_ms"] = String(format: "%.0f", max)
                    attrs["hang_count"] = String(samples)
                }
            }
            if let exit = payload.applicationExitMetrics {
                attrs["exits_abnormal"] = String(exit.foregroundExitData.cumulativeAbnormalExitCount)
                attrs["exits_watchdog"] = String(exit.foregroundExitData.cumulativeAppWatchdogExitCount)
                attrs["exits_memory"] = String(exit.foregroundExitData.cumulativeMemoryResourceLimitExitCount)
            }

            // only ship payloads that carried something useful
            if attrs.keys.contains(where: { $0.hasPrefix("launch_") || $0.hasPrefix("hang_") || $0.hasPrefix("exits_") }) {
                events.enqueue(OleusOTLP.Record(
                    timeMs: payload.timeStampEnd.timeIntervalSince1970 * 1000,
                    severity: "INFO",
                    body: "metrickit_daily",
                    attributes: attrs
                ))
            }
        }
    }

    /// Weighted average / max / total samples from an MXHistogram, in ms.
    private func summarize<U: Unit>(_ histogram: MXHistogram<U>) -> (avg: Double, max: Double, samples: Int) {
        var weighted = 0.0
        var maxMs = 0.0
        var total = 0
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<U> {
            let midMs = ms(bucket.bucketStart) + (ms(bucket.bucketEnd) - ms(bucket.bucketStart)) / 2
            weighted += midMs * Double(bucket.bucketCount)
            maxMs = Swift.max(maxMs, ms(bucket.bucketEnd))
            total += Int(bucket.bucketCount)
        }
        return (total > 0 ? weighted / Double(total) : 0, maxMs, total)
    }

    private func ms<U: Unit>(_ measurement: Measurement<U>) -> Double {
        if let duration = measurement as? Measurement<UnitDuration> {
            return duration.converted(to: .milliseconds).value
        }
        return measurement.value
    }

    private func ship(kind: String, severity: String, body: String, callStack: MXCallStackTree) {
        var attrs = OleusOTLP.baseAttributes(config: config, sessionId: nil)
        attrs["error_type"] = kind
        attrs["crash_source"] = "metrickit"
        if let stackJSON = String(data: callStack.jsonRepresentation(), encoding: .utf8) {
            // MXCallStackTree JSON carries binary UUIDs + offsets — symbolicatable server-side
            attrs["error_stack"] = String(stackJSON.prefix(64 * 1024))
        }
        events.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: severity,
            body: body,
            attributes: attrs
        ))
    }
}
#endif
