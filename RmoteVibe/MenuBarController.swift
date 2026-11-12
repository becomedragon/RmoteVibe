import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let remoteItem = NSMenuItem()
    private let buttonItem = NSMenuItem()
    private let touchItem = NSMenuItem()
    private let micItem = NSMenuItem()
    private let captureItem = NSMenuItem()
    private let voiceItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    var showSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        for item in [remoteItem, buttonItem, touchItem, micItem, captureItem, voiceItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        quitItem.target = self
        quitItem.action = #selector(quit)
        menu.addItem(quitItem)
        statusItem.menu = menu
        if let image = NSImage(named: "MenuBarRemote") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    func refresh() {
        remoteItem.title = model.remoteText()
        buttonItem.title = model.buttonText()
        touchItem.title = model.touch.statusText
        micItem.title = model.micText()
        captureItem.title = model.captureText()
        voiceItem.title = model.voiceText()
        settingsItem.title = NSLocalizedString("menu.pair", comment: "")
        quitItem.title = NSLocalizedString("menu.quit", comment: "")
        statusItem.button?.title = ""
        if statusItem.button?.image == nil {
            if let image = NSImage(named: "MenuBarRemote") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                statusItem.button?.image = image
            } else {
                statusItem.button?.title = "R"
            }
        }
        statusItem.button?.appearsDisabled = !model.remote.isConnected && !model.talk.isHoldingSiri
        statusItem.button?.toolTip = "RmoteVibe"
    }

    @objc private func openSettings() {
        showSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
