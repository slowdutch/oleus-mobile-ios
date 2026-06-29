import Foundation

/// In-memory custom metrics accumulator.
///
/// Collects gauge samples (last-write-wins), delta counters, and histogram
/// samples between flushes, then ships a single OTLP/HTTP metrics payload
/// to /v1/metrics every `flushInterval` seconds.
///
/// Pipeline: SDK → /otlp/v1/metrics → OTEL collector → VictoriaMetrics
/// (Prometheus remote-write) — metrics become queryable time-series, not
/// log records.
///
/// Aggregation semantics per flush window:
///   gauge     — last recorded value
///   counter   — sum of all increments (delta; resets after each flush)
///   histogram — full distribution (count, sum, min, max, bucket counts; resets after each flush)
final class MetricsQueue {

    // ms-scale bucket boundaries suitable for latencies, frame times, durations.
    static let bucketBounds: [Double] = [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

    // MARK: – types

    struct MetricKey: Hashable {
        let name: String
        let tags: [String: String]
        func hash(into h: inout Hasher) {
            h.combine(name)
            for (k, v) in tags.sorted(by: { $0.key < $1.key }) { h.combine(k); h.combine(v) }
        }
        static func == (l: Self, r: Self) -> Bool { l.name == r.name && l.tags == r.tags }
    }

    struct HistState {
        var count: Int    = 0
        var sum: Double   = 0
        var min: Double   = .infinity
        var max: Double   = -.infinity
        var buckets: [Int]
        var startMs: Double
        init(startMs: Double) {
            self.startMs = startMs
            self.buckets = Array(repeating: 0, count: MetricsQueue.bucketBounds.count + 1)
        }
        mutating func record(_ v: Double) {
            count += 1; sum += v
            if v < min { min = v }
            if v > max { max = v }
            for (i, bound) in MetricsQueue.bucketBounds.enumerated() {
                if v <= bound { buckets[i] += 1; return }
            }
            buckets[buckets.endIndex - 1] += 1
        }
    }

    // MARK: – state

    private let config: OleusConfig
    private let q = DispatchQueue(label: "io.oleus.metrics")
    private var timer: DispatchSourceTimer?
    private let flushInterval: TimeInterval = 30

    private var gauges:     [MetricKey: Double]                      = [:]
    private var counters:   [MetricKey: (sum: Double, startMs: Double)] = [:]
    private var histograms: [MetricKey: HistState]                   = [:]

    // MARK: – init

    init(config: OleusConfig) {
        self.config = config
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    // MARK: – public API (thread-safe)

    func recordGauge(_ name: String, value: Double, tags: [String: String]) {
        q.async { [self] in
            gauges[MetricKey(name: name, tags: tags)] = value
        }
    }

    func recordIncrement(_ name: String, by delta: Double, tags: [String: String]) {
        let nowMs = Date().timeIntervalSince1970 * 1_000
        q.async { [self] in
            let key = MetricKey(name: name, tags: tags)
            if var c = counters[key] { c.sum += delta; counters[key] = c }
            else { counters[key] = (sum: delta, startMs: nowMs) }
        }
    }

    func recordHistogram(_ name: String, value: Double, tags: [String: String]) {
        let nowMs = Date().timeIntervalSince1970 * 1_000
        q.async { [self] in
            let key = MetricKey(name: name, tags: tags)
            var h = histograms[key] ?? HistState(startMs: nowMs)
            h.record(value)
            histograms[key] = h
        }
    }

    func flush() { q.async { [self] in flushLocked() } }

    // MARK: – private

    private func flushLocked() {
        guard !gauges.isEmpty || !counters.isEmpty || !histograms.isEmpty else { return }

        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        var metrics: [[String: Any]] = []

        for (key, value) in gauges {
            metrics.append(otlpGauge(key: key, value: value, timeNs: nowNs))
        }
        for (key, c) in counters where c.sum > 0 {
            metrics.append(otlpSum(key: key, sum: c.sum, startNs: Int64(c.startMs * 1_000_000), timeNs: nowNs))
        }
        for (key, h) in histograms where h.count > 0 {
            metrics.append(otlpHistogram(key: key, h: h, startNs: Int64(h.startMs * 1_000_000), timeNs: nowNs))
        }

        // reset delta accumulators; gauges persist (last-write-wins)
        let nowMs = Date().timeIntervalSince1970 * 1_000
        for key in counters.keys { counters[key] = (sum: 0, startMs: nowMs) }
        histograms = [:]

        let payload: [String: Any] = [
            "resourceMetrics": [[
                "resource": ["attributes": resourceAttrs()],
                "scopeMetrics": [[
                    "scope": ["name": "io.oleus.mobile", "version": "1.0"],
                    "metrics": metrics,
                ]],
            ]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: config.endpoint.appendingPathComponent("v1/metrics"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: – OTLP envelope builders

    private func resourceAttrs() -> [[String: Any]] {
        [
            ["key": "service.name",           "value": ["stringValue": config.service]],
            ["key": "service.version",        "value": ["stringValue": config.release]],
            ["key": "platform",               "value": ["stringValue": "ios"]],
            ["key": "deployment.environment", "value": ["stringValue": config.environment]],
        ]
    }

    private func otlpAttrs(_ tags: [String: String]) -> [[String: Any]] {
        tags.map { ["key": $0.key, "value": ["stringValue": $0.value]] }
    }

    private func otlpGauge(key: MetricKey, value: Double, timeNs: Int64) -> [String: Any] {
        ["name": key.name,
         "gauge": ["dataPoints": [[
             "timeUnixNano": String(timeNs),
             "asDouble": value,
             "attributes": otlpAttrs(key.tags),
         ]]]]
    }

    private func otlpSum(key: MetricKey, sum: Double, startNs: Int64, timeNs: Int64) -> [String: Any] {
        ["name": key.name,
         "sum": [
             "dataPoints": [[
                 "startTimeUnixNano": String(startNs),
                 "timeUnixNano":      String(timeNs),
                 "asDouble":          sum,
                 "attributes":        otlpAttrs(key.tags),
             ]],
             "aggregationTemporality": 2,  // DELTA
             "isMonotonic": true,
         ]]
    }

    private func otlpHistogram(key: MetricKey, h: HistState, startNs: Int64, timeNs: Int64) -> [String: Any] {
        // OTLP expects cumulative bucket counts (each bucket = values <= bound).
        // We store per-bound counts, so accumulate here.
        var cumulative = [Int]()
        var running = 0
        for c in h.buckets { running += c; cumulative.append(running) }

        return ["name": key.name,
                "histogram": [
                    "dataPoints": [[
                        "startTimeUnixNano": String(startNs),
                        "timeUnixNano":      String(timeNs),
                        "count":             String(h.count),
                        "sum":               h.sum,
                        "min":               h.min == .infinity  ? 0 : h.min,
                        "max":               h.max == -.infinity ? 0 : h.max,
                        "explicitBounds":    Self.bucketBounds,
                        "bucketCounts":      cumulative.map { String($0) },
                        "attributes":        otlpAttrs(key.tags),
                    ]],
                    "aggregationTemporality": 2,  // DELTA
                ]]
    }
}
