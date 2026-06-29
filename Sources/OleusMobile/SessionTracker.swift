import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Session lifecycle → session_start / session_end events.
///
/// A session starts on SDK start and on foregrounding after >30 min in the
/// background; it ends on backgrounding. Session ids ride on every record
/// (crashes included), which is what makes crash-free-sessions computable.
/// A session marker file persists the live session so a hard crash still
/// attributes to it on the next launch.
final class SessionTracker {
    private let config: OleusConfig
    private let events: EventQueue
    private let lock = NSLock()
    private var backgroundedAt: Date?
    private let sessionTimeout: TimeInterval = 30 * 60

    private(set) var sessionId: String

    init(config: OleusConfig, events: EventQueue) {
        self.config = config
        self.events = events
        self.sessionId = UUID().uuidString
        persistMarker()
        emit(event: "session_start")
        observeLifecycle()
    }

    /// Session id active when the previous process died (for crash attribution).
    static func previousSessionId() -> String? {
        try? String(contentsOf: OleusPaths.sessionMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ── lifecycle ────────────────────────────────────────────────────────────

    private func observeLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterBackground()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.willEnterForeground()
        }
        #endif
    }

    private func didEnterBackground() {
        lock.lock(); defer { lock.unlock() }
        backgroundedAt = Date()
        emit(event: "session_end")
        events.flush()
    }

    private func willEnterForeground() {
        lock.lock(); defer { lock.unlock() }
        if let bg = backgroundedAt, Date().timeIntervalSince(bg) > sessionTimeout {
            sessionId = UUID().uuidString
            persistMarker()
            emit(event: "session_start")
        } else if backgroundedAt != nil {
            // same session resumes — re-mark it as live
            emit(event: "session_start", attributes: ["resumed": "true"])
        }
        backgroundedAt = nil
    }

    private func persistMarker() {
        try? sessionId.write(to: OleusPaths.sessionMarker, atomically: true, encoding: .utf8)
    }

    private func emit(event: String, attributes: [String: String] = [:]) {
        var attrs = OleusOTLP.baseAttributes(config: config, sessionId: sessionId)
        attrs["event.name"] = event
        attrs["event.domain"] = "oleus"
        for (k, v) in attributes { attrs[k] = v }
        events.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: "INFO",
            body: event,
            attributes: attrs
        ))
    }
}
