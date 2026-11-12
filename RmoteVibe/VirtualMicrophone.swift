import Foundation

/// Installs the HAL plug-in and owns the ring the plug-in reads.
/// The system default input is left alone. 豆包 selects RmoteVibe Mic itself.
final class VirtualMicrophone {
    private(set) var ringError: Int32 = 0
    private(set) var installed = false
    private(set) var installing = false
    private(set) var installError: String?
    private(set) var bundleMissing = false

    var onChange: (() -> Void)?

    func start() {
        ringError = RMVRingOpenWriter()
        RMVRingUseMac()
        refreshInstalled()
    }

    func stop() {
        RMVRingCloseWriter()
    }

    func refreshInstalled() {
        installed = SystemInput.deviceExists(uid: String(cString: RMVDeviceUID))
    }

    func install() {
        guard !installing else { return }
        installError = nil
        bundleMissing = false
        guard let source = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RmoteVibeMic.driver"),
              FileManager.default.fileExists(atPath: source.path) else {
            bundleMissing = true
            onChange?()
            return
        }
        installing = true
        onChange?()
        let destination = "/Library/Audio/Plug-Ins/HAL/RmoteVibeMic.driver"
        let command = "rm -rf \(shellQuote(destination)) && mkdir -p /Library/Audio/Plug-Ins/HAL && cp -R \(shellQuote(source.path)) \(shellQuote(destination)) && (killall coreaudiod || true)"
        let script = "do shell script \"\(escapeAppleScript(command))\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.installError = error[NSAppleScript.errorMessage] as? String ?? String(describing: error)
                    self.installing = false
                    self.onChange?()
                    return
                }
                self.poll(attempt: 0)
            }
        }
    }

    private func poll(attempt: Int) {
        refreshInstalled()
        if installed || attempt >= 12 {
            installing = false
            onChange?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll(attempt: attempt + 1)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
