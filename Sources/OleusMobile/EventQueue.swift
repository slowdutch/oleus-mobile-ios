import Foundation

/// Disk-backed, batched OTLP shipper.
///
/// Every event is persisted to the queue directory first, then uploaded in
/// batches (size- or timer-triggered). Files are deleted only on a 2xx
/// response, so events survive crashes, offline periods, and process kills —
/// the same guarantee for non-fatal captures as for crashes.
final class EventQueue {
    private let config: OleusConfig
    private let queue = DispatchQueue(label: "io.oleus.eventqueue")
    private var timer: DispatchSourceTimer?
    private let maxQueuedFiles = 200
    private let flushInterval: TimeInterval = 10

    init(config: OleusConfig) {
        self.config = config
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    /// Persist a record and schedule it for upload.
    func enqueue(_ record: OleusOTLP.Record) {
        queue.async { [self] in
            let entry: [String: Any] = [
                "timeMs": record.timeMs,
                "severity": record.severity,
                "body": record.body,
                "attributes": record.attributes,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
            let file = OleusPaths.eventQueue.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
            try? data.write(to: file, options: .atomic)
            trimLocked()
        }
    }

    func flush() {
        queue.async { [self] in flushLocked() }
    }

    // ── private (always on `queue`) ──────────────────────────────────────────

    private func pendingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: OleusPaths.eventQueue, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func trimLocked() {
        let files = pendingFiles()
        guard files.count > maxQueuedFiles else { return }
        for file in files.prefix(files.count - maxQueuedFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func flushLocked() {
        let files = Array(pendingFiles().prefix(50))
        guard !files.isEmpty else { return }

        var records: [OleusOTLP.Record] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = entry["body"] as? String else { continue }
            records.append(OleusOTLP.Record(
                timeMs: entry["timeMs"] as? Double ?? Date().timeIntervalSince1970 * 1000,
                severity: entry["severity"] as? String ?? "INFO",
                body: body,
                attributes: entry["attributes"] as? [String: String] ?? [:]
            ))
        }
        guard !records.isEmpty else {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }

        let payload = OleusOTLP.envelope(config: config, records: records)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: config.endpoint.appendingPathComponent("v1/logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            self.queue.async {
                files.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
        task.resume()
    }
}
