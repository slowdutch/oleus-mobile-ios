import Foundation
import Security

/// A lightweight distributed tracing span.
///
/// Spans are shipped as OTLP log events with trace/span IDs so they can be
/// correlated across services in the Oleus dashboard. Use [childSpan] to nest
/// operations under the same trace.
///
/// ```swift
/// let span = OleusMobile.startSpan("api.call", attributes: ["endpoint": "/events"])
/// defer { span.finish() }
/// // ... do work ...
/// span.setTag("status_code", "200")
/// ```
public final class OleusSpan {
    public let traceId: String
    public let spanId:  String
    public let name:    String

    private let startMs:  Double
    private var tags:     [String: String]
    private var status:   String = "ok"
    private let onFinish: (OleusSpan) -> Void
    private var finished  = false

    internal init(name: String, traceId: String?, attributes: [String: String],
                  onFinish: @escaping (OleusSpan) -> Void) {
        self.name     = name
        self.traceId  = traceId ?? OleusSpan.randomHex(32)
        self.spanId   = OleusSpan.randomHex(16)
        self.startMs  = Date().timeIntervalSince1970 * 1_000
        self.tags     = attributes
        self.onFinish = onFinish
    }

    /// Add or update a tag on this span.
    public func setTag(_ key: String, _ value: String) { tags[key] = value }

    /// Mark the span as errored.
    public func setError(_ message: String) {
        status = "error"
        tags["error.message"] = message
    }

    /// Start a child span that inherits this span's `traceId`.
    public func childSpan(_ name: String, attributes: [String: String] = [:]) -> OleusSpan {
        var childAttrs = attributes
        childAttrs["parent_span_id"] = spanId
        return OleusMobile.startSpan(name, traceId: traceId, attributes: childAttrs)
    }

    /// Ship the span. Subsequent calls are no-ops.
    public func finish() {
        guard !finished else { return }
        finished = true
        tags["span.duration_ms"] = String(format: "%.0f", Date().timeIntervalSince1970 * 1_000 - startMs)
        tags["span.status"] = status
        onFinish(self)
    }

    internal var allTags:       [String: String] { tags }
    internal var startTimestamp: Double          { startMs }
    internal var spanStatus:    String           { status }

    private static func randomHex(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length / 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
