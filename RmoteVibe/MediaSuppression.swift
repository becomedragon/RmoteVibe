import AppKit
import Foundation

/// Remaps this remote's volume, mute, and play/pause usages to the keyboard
/// null usage so macOS does not also act. IOHID still reports the original usage.
///
/// The map does not survive sleep, reboot, or the remote disconnecting.
/// This app puts it back after wake, on connect, and every few seconds while
/// it is running. Quitting removes it. Nothing here keeps it across sleep
/// if the process is not running to put it back.
final class MediaSuppression {
    private(set) var statusText = NSLocalizedString("suppress.idle", comment: "")

    private let queue = DispatchQueue(label: "dev.rmotevibe.suppress")
    private var wakeObserver: NSObjectProtocol?
    private var baseEntries: [[String: Any]] = []
    private var haveBase = false

    /// Page in the high 32 bits, usage in the low 32. Null destination is page 0x07 usage 0.
    private static let sources: [UInt64] = [
        (0x0C << 32) | 0xE9,
        (0x0C << 32) | 0xEA,
        (0x0C << 32) | 0xE2,
        (0x0C << 32) | 0xCD
    ]
    private static let destination: UInt64 = 0x07 << 32
    private static let matching = "{\"VendorID\":76,\"ProductID\":789}"

    func start() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.apply()
            }
        }
        apply()
    }

    func apply() {
        queue.async { [weak self] in
            self?.install(removing: false)
        }
    }

    func clear() {
        queue.sync { [weak self] in
            self?.install(removing: true)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func install(removing: Bool) {
        let read = run(["property", "--matching", Self.matching, "--get", "UserKeyMapping"])
        if read.status == 0, let parsed = parseEntries(read.text) {
            baseEntries = parsed.filter { !Self.isOurs($0) }
            haveBase = true
        }
        let entries: [[String: Any]]
        if removing {
            guard haveBase else {
                publish(NSLocalizedString("suppress.idle", comment: ""))
                return
            }
            entries = baseEntries
        } else if !haveBase {
            let detail = read.text.isEmpty ? "hidutil \(read.status)" : String(read.text.prefix(180))
            publish(String(format: NSLocalizedString("suppress.failed", comment: ""), detail))
            return
        } else {
            entries = baseEntries + Self.ourEntries()
        }
        let body = ["UserKeyMapping": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else {
            publish(NSLocalizedString("suppress.failed", comment: "encode"))
            return
        }
        let wrote = run(["property", "--matching", Self.matching, "--set", json])
        if wrote.status != 0 {
            publish(String(format: NSLocalizedString("suppress.failed", comment: ""), wrote.text))
            return
        }
        if removing {
            publish(NSLocalizedString("suppress.cleared", comment: ""))
        } else {
            publish(NSLocalizedString("suppress.on", comment: ""))
        }
    }

    private func publish(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = text
        }
    }

    private func parseEntries(_ text: String) -> [[String: Any]]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" {
            return []
        }
        // hidutil prints a table of (null) maps for this BLE HID stack.
        if trimmed.hasPrefix("RegistryID") {
            return []
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if object is NSNull {
            return []
        }
        if let rows = object as? [[String: Any]] {
            return rows
        }
        if let root = object as? [String: Any] {
            if root.isEmpty || root["UserKeyMapping"] is NSNull {
                return []
            }
            if let rows = root["UserKeyMapping"] as? [[String: Any]] {
                return rows
            }
        }
        return nil
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let src = number(entry["HIDKeyboardModifierMappingSrc"]) else { return false }
        return sources.contains(src)
    }

    private static func ourEntries() -> [[String: Any]] {
        sources.map { src in
            [
                "HIDKeyboardModifierMappingSrc": NSNumber(value: src),
                "HIDKeyboardModifierMappingDst": NSNumber(value: destination)
            ]
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private func run(_ arguments: [String]) -> (status: Int32, text: String) {
        let task = Process()
        let output = Pipe()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = errors
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        task.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (text + err).trimmingCharacters(in: .whitespacesAndNewlines)
        return (task.terminationStatus, combined)
    }
}
