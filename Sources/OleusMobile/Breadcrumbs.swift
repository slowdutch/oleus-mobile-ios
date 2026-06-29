import Foundation

/// Thread-safe breadcrumb trail, persisted to disk on every add.
///
/// The signal handler never reads breadcrumbs — the next-launch reporter
/// loads this file instead, so crumbs survive hard crashes without any
/// signal-context work.
final class Breadcrumbs {
    nonisolated(unsafe) static let shared = Breadcrumbs()

    private let queue = DispatchQueue(label: "io.oleus.breadcrumbs")
    private var crumbs: [[String: Any]] = []
    private(set) var maxCrumbs: Int = 50

    func configure(maxCrumbs: Int) { self.maxCrumbs = max(1, maxCrumbs) }

    private init() {
        // load the trail from the previous run before the reaper consumes it
        if let data = try? Data(contentsOf: OleusPaths.breadcrumbs) {
            crumbs = data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
        }
    }

    func add(message: String, category: String, attributes: [String: Any]?) {
        queue.async { [self] in
            var crumb: [String: Any] = [
                "timestamp": Date().timeIntervalSince1970 * 1000,
                "message": message,
                "category": category,
            ]
            if let attrs = attributes {
                crumb["attributes"] = attrs.mapValues { String(describing: $0) }
            }
            crumbs.append(crumb)
            if crumbs.count > maxCrumbs { crumbs.removeFirst(crumbs.count - maxCrumbs) }
            persistLocked()
        }
    }

    func snapshotJSON() -> String {
        queue.sync {
            guard let data = try? JSONSerialization.data(withJSONObject: crumbs) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// Trail as it was when the previous process died.
    static func previousTrailJSON() -> String {
        guard let data = try? Data(contentsOf: OleusPaths.breadcrumbs) else { return "[]" }
        let trail = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        guard let out = try? JSONSerialization.data(withJSONObject: trail) else { return "[]" }
        return String(data: out, encoding: .utf8) ?? "[]"
    }

    private func persistLocked() {
        var lines = Data()
        for crumb in crumbs {
            if let data = try? JSONSerialization.data(withJSONObject: crumb) {
                lines.append(data)
                lines.append(UInt8(ascii: "\n"))
            }
        }
        try? lines.write(to: OleusPaths.breadcrumbs, options: .atomic)
    }
}
