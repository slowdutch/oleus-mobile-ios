import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Immutable SDK configuration captured at start().
struct OleusConfig {
    let endpoint: URL
    let service: String
    let apiKey: String?
    let environment: String

    var release: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }
}

enum OleusPaths {
    /// Application Support (not Caches — the OS may purge Caches under
    /// pressure, which is exactly when crash data matters).
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OleusMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var crashReport: URL { root.appendingPathComponent("crash.pending") }
    static var exceptionReport: URL { root.appendingPathComponent("exception.pending") }
    static var binaryImages: URL { root.appendingPathComponent("images.json") }
    static var breadcrumbs: URL { root.appendingPathComponent("breadcrumbs.jsonl") }
    static var sessionMarker: URL { root.appendingPathComponent("session.current") }
    static var eventQueue: URL {
        let dir = root.appendingPathComponent("queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum OleusDevice {
    static var model: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var deviceId: String {
        #if canImport(UIKit) && !os(watchOS)
        if let id = UIDevice.current.identifierForVendor?.uuidString { return id }
        #endif
        // stable per-install fallback
        let key = "io.oleus.device_id"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}

/// Builds the OTLP/HTTP JSON envelope for a batch of log records.
enum OleusOTLP {
    struct Record {
        let timeMs: Double
        let severity: String
        let body: String
        var attributes: [String: String]
    }

    static func envelope(config: OleusConfig, records: [Record]) -> [String: Any] {
        let logRecords: [[String: Any]] = records.map { r in
            [
                "timeUnixNano": String(Int64(r.timeMs * 1_000_000)),
                "severityText": r.severity,
                "body": ["stringValue": r.body],
                "attributes": r.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
            ]
        }
        return [
            "resourceLogs": [[
                "resource": [
                    "attributes": [
                        ["key": "service.name", "value": ["stringValue": config.service]],
                        ["key": "service.version", "value": ["stringValue": config.release]],
                        ["key": "deployment.environment", "value": ["stringValue": config.environment]],
                    ],
                ],
                "scopeLogs": [["logRecords": logRecords]],
            ]],
        ]
    }

    /// Attributes common to every mobile record.
    static func baseAttributes(config: OleusConfig, sessionId: String?) -> [String: String] {
        var attrs = [
            "platform": "ios",
            "mobile": "true",
            "device_model": OleusDevice.model,
            "os_version": OleusDevice.osVersion,
            "app_version": config.release,
            "release": config.release,
            "device.id": OleusDevice.deviceId,
        ]
        if let sessionId = sessionId { attrs["session.id"] = sessionId }
        return attrs
    }
}
