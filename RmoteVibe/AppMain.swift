import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menu: MenuBarController?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = MenuBarController(model: model)
        let settings = SettingsWindowController(model: model)
        self.menu = menu
        self.settings = settings
        menu.showSettings = { [weak settings] in
            settings?.show()
        }
        model.onChange = { [weak menu, weak settings] in
            menu?.refresh()
            settings?.refresh()
        }
        model.start()
        if CommandLine.arguments.contains("--settings")
            || FileManager.default.fileExists(atPath: "/tmp/rmv-open-settings") {
            try? FileManager.default.removeItem(atPath: "/tmp/rmv-open-settings")
            settings.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

private let appDelegate = AppDelegate()

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
