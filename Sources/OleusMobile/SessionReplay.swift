#if canImport(UIKit)
import UIKit

final class SessionReplay {
    private let config: OleusConfig
    private let events: EventQueue
    private let sessionId: String
    private var timer: Timer?
    private let captureIntervalSeconds: TimeInterval = 2.0

    init(config: OleusConfig, events: EventQueue, sessionId: String) {
        self.config = config
        self.events = events
        self.sessionId = sessionId
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: captureIntervalSeconds, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func captureFrame() {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        let wireframe = buildWireframe(view: window)
        guard let data = try? JSONSerialization.data(withJSONObject: wireframe),
              let json = String(data: data, encoding: .utf8) else { return }
        var attrs = OleusOTLP.baseAttributes(config: config, sessionId: sessionId)
        attrs["event.name"] = "replay_segment"
        attrs["event.domain"] = "oleus"
        attrs["wireframe"] = json
        events.enqueue(OleusOTLP.Record(
            timeMs: Date().timeIntervalSince1970 * 1000,
            severity: "INFO",
            body: "replay_segment",
            attributes: attrs
        ))
    }

    private func buildWireframe(view: UIView) -> [String: Any] {
        var node: [String: Any] = [
            "type":   String(describing: type(of: view)),
            "frame":  ["x": view.frame.origin.x, "y": view.frame.origin.y,
                       "w": view.frame.size.width, "h": view.frame.size.height],
            "hidden": view.isHidden,
            "alpha":  view.alpha,
        ]
        if let label = view as? UILabel {
            node["text"] = label.isSensitive ? "[masked]" : label.text ?? ""
        } else if view is UITextField || view is UITextView {
            node["text"] = "[masked]"
        }
        node["children"] = view.subviews.map { buildWireframe(view: $0) }
        return node
    }
}

private extension UIView {
    var isSensitive: Bool {
        let hint = accessibilityLabel?.lowercased() ?? ""
        return hint.contains("password") || hint.contains("card") || hint.contains("secret")
    }
}
#endif
