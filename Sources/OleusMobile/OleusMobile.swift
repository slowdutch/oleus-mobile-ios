import Foundation
import OleusCrashCore

#if canImport(UIKit)
import UIKit
#endif

/// Oleus iOS SDK — crash reporting, sessions, breadcrumbs, MetricKit.
///
/// Crash capture is split across two contexts:
///  - **At crash time** the C core (`OleusCrashCore`) runs an
///    async-signal-safe handler: raw frame addresses via a frame-pointer
///    walk, written with `write(2)` to a pre-arranged path. Nothing in the
///    signal context allocates or touches the ObjC/Swift runtime.
///  - **On next launch** this layer pairs those addresses with the persisted
///    dyld binary-image list (UUIDs + load addresses), breadcrumb trail, and
///    last session id, and ships the report through the disk-backed queue.
///
/// Usage:
///     OleusMobile.start(
///         endpoint: URL(string: "https://oleus.example.com/otlp")!,
///         service: "rondo-ios",
///         apiKey: "<OLEUS_INGEST_KEY_IOS>"
///     )
public final class OleusMobile {
    private static let lock = NSLock()
    private static var config: OleusConfig?
    private static var events: EventQueue?
    private static var sessions: SessionTracker?
    private static var previousExceptionHandler: ((NSException) -> Void)?
    #if canImport(MetricKit) && os(iOS)
    private static var metricKit: MetricKitObserver?
    #endif

    // ── public API ────────────────────────────────────────────────────────────

    /// Initialize the SDK. Call once, as early as possible in app launch.
    public static func start(
        endpoint: URL,
        service: String,
        apiKey: String? = nil,
        environment: String = "production"
    ) {
        lock.lock(); defer { lock.unlock() }
        guard config == nil else { return }

        let cfg = OleusConfig(endpoint: endpoint, service: service, apiKey: apiKey, environment: environment)
        config = cfg
        let queue = EventQueue(config: cfg)
        events = queue

        // 1. report whatever the previous run left behind (before new session
        //    overwrites the marker / breadcrumb files)
        reapPendingCrash(config: cfg, events: queue)
        reapPendingException(config: cfg, events: queue)

        // 2. persist the dyld image list for the *next* crash
        BinaryImages.persist()

        // 3. install the async-signal-safe core
        _ = OleusPaths.crashReport.path.withCString { oleus_crash_install($0) }

        // 4. NSException handler — chains any previously installed handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            OleusMobile.handleUncaughtException(exception)
        }

        // 5. sessions (start event), MetricKit cross-check
        sessions = SessionTracker(config: cfg, events: queue)
        #if canImport(MetricKit) && os(iOS)
        metricKit = MetricKitObserver(config: cfg, events: queue)
        #endif
    }

    @available(*, deprecated, renamed: "start(endpoint:service:apiKey:environment:)")
    public static func initialize(endpoint: URL, service: String, environment: String = "production") {
        start(endpoint: endpoint, service: service, apiKey: nil, environment: environment)
    }

    /// Capture a non-fatal error. Batched through the disk-backed queue.
    public static func capture(error: Error, context: [String: Any]? = nil) {
        guard let cfg = config, let queue = events else { return }
        var attrs = OleusOTLP.baseAttributes(config: cfg, sessionId: sessions?.sessionId)
        attrs["error_type"] = String(describing: type(of: error))
        attrs["error_stack"] = Thread.callStackSymbols.joined(separator: "\n")
        attrs["breadcrumbs"] = Breadcrumbs.shared.snapshotJSON()
        if let context = context {
            for (k, v) in context { attrs[k] = String(describing: v) }
        }
        queue.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: "ERROR",
            body: error.localizedDescription,
            attributes: attrs
        ))
    }

    /// Add a breadcrumb (screen navigation, key taps, network milestones).
    public static func addBreadcrumb(message: String, category: String = "default", attributes: [String: Any]? = nil) {
        Breadcrumbs.shared.add(message: message, category: category, attributes: attributes)
    }

    /// Record a screen view — call from viewDidAppear / SwiftUI .onAppear.
    /// Pass `renderMs` to also capture the screen's render/TTI duration.
    public static func trackScreen(_ name: String, renderMs: Double? = nil) {
        guard let cfg = config, let queue = events else { return }
        Breadcrumbs.shared.add(message: name, category: "navigation", attributes: nil)
        var attrs = OleusOTLP.baseAttributes(config: cfg, sessionId: sessions?.sessionId)
        attrs["event.name"] = "screen_view"
        attrs["event.domain"] = "oleus"
        attrs["screen"] = name
        if let renderMs = renderMs { attrs["render_ms"] = String(format: "%.0f", renderMs) }
        queue.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: "INFO",
            body: "screen_view",
            attributes: attrs
        ))
    }

    /// Force-flush queued events (e.g. before a controlled shutdown).
    public static func flush() {
        events?.flush()
    }

    // ── NSException path (normal context — Foundation is safe here) ──────────

    private static func handleUncaughtException(_ exception: NSException) {
        let report: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
            "stack": exception.callStackSymbols.joined(separator: "\n"),
            "stack_addresses": exception.callStackReturnAddresses.map { String(format: "0x%llx", $0.uint64Value) },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: OleusPaths.exceptionReport, options: .atomic)
        }
        // chain whatever was installed before us (e.g. another reporter)
        previousExceptionHandler?(exception)
    }

    // ── next-launch reapers ───────────────────────────────────────────────────

    private static func reapPendingCrash(config: OleusConfig, events: EventQueue) {
        let path = OleusPaths.crashReport
        guard path.path.withCString({ oleus_crash_has_pending($0) }) == 1,
              let raw = try? String(contentsOf: path, encoding: .utf8) else { return }
        defer { try? FileManager.default.removeItem(at: path) }

        var signalName = "SIGNAL"
        var fault = ""
        var frames: [String] = []
        for line in raw.split(separator: "\n") {
            if line.hasPrefix("name:") { signalName = String(line.dropFirst(5)) }
            else if line.hasPrefix("fault:") { fault = String(line.dropFirst(6)) }
            else if line.hasPrefix("0x") { frames.append(String(line)) }
            // "signal:<n>" line intentionally unused — name carries it
        }
        guard !frames.isEmpty else { return }

        var attrs = OleusOTLP.baseAttributes(config: config, sessionId: SessionTracker.previousSessionId())
        attrs["error_type"] = signalName
        attrs["error_stack"] = frames.joined(separator: "\n")
        attrs["binary_images"] = BinaryImages.loadPersisted()
        attrs["breadcrumbs"] = Breadcrumbs.previousTrailJSON()
        attrs["fault_address"] = fault
        attrs["crash_source"] = "signal"

        events.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: "FATAL",
            body: "\(signalName) (fault \(fault))",
            attributes: attrs
        ))
        events.flush()
    }

    private static func reapPendingException(config: OleusConfig, events: EventQueue) {
        let path = OleusPaths.exceptionReport
        guard let data = try? Data(contentsOf: path),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        defer { try? FileManager.default.removeItem(at: path) }

        var attrs = OleusOTLP.baseAttributes(config: config, sessionId: SessionTracker.previousSessionId())
        attrs["error_type"] = report["name"] as? String ?? "NSException"
        // symbol stack for debug builds; raw addresses + image list for release
        attrs["error_stack"] = (report["stack_addresses"] as? [String])?.joined(separator: "\n")
            ?? report["stack"] as? String ?? ""
        attrs["binary_images"] = BinaryImages.loadPersisted()
        attrs["breadcrumbs"] = Breadcrumbs.previousTrailJSON()
        attrs["crash_source"] = "nsexception"

        let name = report["name"] as? String ?? "NSException"
        let reason = report["reason"] as? String ?? ""
        events.enqueue(OleusOTLP.Record(
            timeMs: report["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000,
            severity: "FATAL",
            body: "\(name): \(reason)",
            attributes: attrs
        ))
        events.flush()
    }
}
