import Foundation

#if canImport(UIKit)
import UIKit
import MachO

/// Listens for iOS memory pressure notifications and reports heap stats so
/// crashes that follow an OOM warning can be correlated in the dashboard.
///
/// iOS does not give a pre-OOM kill signal; the best we can do is record the
/// last warning. On the next launch the dashboard will show the warning event
/// immediately before the next session start, making the OOM sequence visible.
final class MemoryMonitor {
    private let onWarning: (_ residentMB: Int, _ availableMB: Int) -> Void
    private var token: NSObjectProtocol?

    init(onWarning: @escaping (_ residentMB: Int, _ availableMB: Int) -> Void) {
        self.onWarning = onWarning
    }

    func start() {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onWarning(self.residentMB(), self.availableMB())
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: – private

    private func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
    }

    /// Available memory via `os_proc_available_memory()` (iOS 13+), falls back to 0.
    private func availableMB() -> Int {
        if #available(iOS 13.0, *) {
            let bytes = os_proc_available_memory()
            return Int(bytes) / (1024 * 1024)
        }
        return 0
    }
}
#endif
