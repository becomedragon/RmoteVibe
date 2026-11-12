import Foundation
import ServiceManagement

/// Registers this menu-bar app with SMAppService. The toggle defaults to on.
/// macOS may still leave the item at “requires approval” until the user allows
/// it under General → Login Items. macOS may still require that click.
enum LoginItem {
    static func apply(enabled: Bool) -> (message: String, failed: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            let message = String(format: NSLocalizedString("login.failed", comment: ""), error.localizedDescription)
            return (message, true)
        }
        return (describe(service.status), false)
    }

    static func describeCurrent() -> String {
        describe(SMAppService.mainApp.status)
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return NSLocalizedString("login.enabled", comment: "")
        case .requiresApproval:
            return NSLocalizedString("login.approval", comment: "")
        case .notRegistered:
            return NSLocalizedString("login.off", comment: "")
        case .notFound:
            return NSLocalizedString("login.notFound", comment: "")
        @unknown default:
            return NSLocalizedString("login.unknown", comment: "")
        }
    }
}
