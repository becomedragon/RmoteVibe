import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var wrappingLabels: [NSTextField] = []
    private var didScrollToTop = false

    private let remoteLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonLabel = NSTextField(wrappingLabelWithString: "")
    private let pairLabel = NSTextField(wrappingLabelWithString: "")
    private let voiceLabel = NSTextField(wrappingLabelWithString: "")
    private let touchLabel = NSTextField(wrappingLabelWithString: "")
    private let suppressLabel = NSTextField(wrappingLabelWithString: "")
    private let micLabel = NSTextField(wrappingLabelWithString: "")
    private let installLabel = NSTextField(wrappingLabelWithString: "")
    private let accessLabel = NSTextField(labelWithString: "")
    private let inputLabel = NSTextField(labelWithString: "")
    private let microphoneLabel = NSTextField(labelWithString: "")

    private let devicePopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()
    private let keyPopup = NSPopUpButton()
    private var actionPopups: [RemoteButton: NSPopUpButton] = [:]
    private let searchButton = NSButton()
    private let pairButton = NSButton()
    private let reconnectButton = NSButton()
    private let installButton = NSButton()
    private let allowButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let restoreButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private var deviceSignature = ""
    private var lastDocHeight: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 420, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.title = NSLocalizedString("settings.title", comment: "")
        build()
        refresh()
        relayout(scrollToTop: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refresh()
        relayout(scrollToTop: !didScrollToTop)
    }

    func refresh() {
        guard window != nil else { return }
        remoteLabel.stringValue = model.remoteText()
        buttonLabel.stringValue = model.buttonText()
        voiceLabel.stringValue = model.voiceText()
        touchLabel.stringValue = model.touch.statusText
        suppressLabel.stringValue = model.suppression.statusText
        micLabel.stringValue = model.micText()
        pairLabel.stringValue = model.pairMessage ?? ""
        installLabel.stringValue = installText()
        accessLabel.stringValue = permissionLine("settings.accessibility", granted: Permissions.accessibility)
        inputLabel.stringValue = permissionLine("settings.input", granted: Permissions.inputMonitoring)
        microphoneLabel.stringValue = permissionLine("settings.microphone", granted: Permissions.microphone)

        searchButton.title = model.searching
            ? NSLocalizedString("settings.searching", comment: "")
            : NSLocalizedString("settings.search", comment: "")
        searchButton.isEnabled = !model.searching
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
        reconnectButton.isEnabled = !model.remote.isConnected && !model.pairing
        reconnectButton.title = model.reconnecting
            ? NSLocalizedString("settings.reconnecting", comment: "")
            : NSLocalizedString("settings.reconnect", comment: "")
        installButton.isEnabled = !model.virtualMic.installing
        installButton.title = model.virtualMic.installing
            ? NSLocalizedString("settings.installing", comment: "")
            : NSLocalizedString("settings.install", comment: "")

        syncPopup(enginePopup, raw: model.preferences.engine.rawValue)
        syncPopup(keyPopup, raw: model.preferences.talkKey.rawValue)
        allowButton.state = model.preferences.allowControlsWhileSpeaking ? .on : .off
        restoreButton.state = model.preferences.restorePreviousInputSource ? .on : .off
        loginButton.state = model.preferences.launchAtLogin ? .on : .off
        loginLabel.stringValue = model.loginStatus
        for (button, popup) in actionPopups {
            syncPopup(popup, raw: model.preferences.action(for: button).rawValue)
        }
        rebuildDevicesIfNeeded()
        if window?.isVisible == true {
            relayout(scrollToTop: false)
        }
    }

    func windowDidResize(_ notification: Notification) {
        relayout(scrollToTop: false)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        scroll.frame = content.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        content.addSubview(scroll)

        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        document.addSubview(stack)

        track(remoteLabel)
        track(buttonLabel)
        track(pairLabel)
        track(voiceLabel)
        track(micLabel)
        track(installLabel)

        add(header("settings.remote"))
        add(wrapping("settings.remote.help"))
        add(remoteLabel)
        add(buttonLabel)
        searchButton.target = self
        searchButton.action = #selector(search)
        searchButton.bezelStyle = .rounded
        add(searchButton)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        add(devicePopup)
        pairButton.target = self
        pairButton.action = #selector(pair)
        pairButton.bezelStyle = .rounded
        pairButton.title = NSLocalizedString("settings.pair", comment: "")
        add(pairButton)
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect)
        reconnectButton.bezelStyle = .rounded
        add(reconnectButton)
        let bluetooth = NSButton(title: NSLocalizedString("settings.bluetooth", comment: ""), target: self, action: #selector(openBluetooth))
        bluetooth.bezelStyle = .rounded
        add(bluetooth)
        add(pairLabel)

        add(gap())
        add(header("settings.voice"))
        add(wrapping("settings.engine"))
        enginePopup.addItem(withTitle: NSLocalizedString("engine.doubao", comment: ""))
        enginePopup.lastItem?.representedObject = Preferences.Engine.doubao.rawValue
        enginePopup.addItem(withTitle: NSLocalizedString("engine.wechat", comment: ""))
        enginePopup.lastItem?.representedObject = Preferences.Engine.wechat.rawValue
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        add(enginePopup)
        add(wrapping("settings.wechat.warning"))
        add(wrapping("settings.talkKey"))
        keyPopup.addItem(withTitle: NSLocalizedString("key.rightCommand", comment: ""))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.rightCommand.rawValue
        keyPopup.addItem(withTitle: NSLocalizedString("key.leftOption", comment: ""))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.leftOption.rawValue
        keyPopup.addItem(withTitle: NSLocalizedString("key.fn", comment: ""))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.fn.rawValue
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)
        add(keyPopup)
        add(wrapping("settings.talkKey.help"))
        restoreButton.title = NSLocalizedString("settings.restore", comment: "")
        restoreButton.target = self
        restoreButton.action = #selector(restoreChanged)
        add(restoreButton)
        add(wrapping("settings.restore.help"))
        add(voiceLabel)

        add(gap())
        add(header("settings.touch"))
        add(wrapping("settings.touch.help"))
        track(touchLabel)
        add(touchLabel)

        add(gap())
        add(header("settings.buttons"))
        add(wrapping("settings.buttons.help"))
        for button in RemoteButton.allCases {
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(button.rawValue)
            for action in MappedAction.allCases {
                popup.addItem(withTitle: NSLocalizedString(action.titleKey, comment: ""))
                popup.lastItem?.representedObject = action.rawValue
            }
            popup.target = self
            popup.action = #selector(actionChanged(_:))
            actionPopups[button] = popup
            add(fieldLabel(button.titleKey))
            add(popup)
        }
        track(suppressLabel)
        add(suppressLabel)
        add(wrapping("settings.suppress.help"))

        add(gap())
        add(header("settings.permissions"))
        add(accessLabel)
        add(button("settings.request", #selector(requestAccess)))
        add(inputLabel)
        add(button("settings.request", #selector(requestInput)))
        add(microphoneLabel)
        add(button("settings.request", #selector(requestMicrophone)))

        add(gap())
        add(header("settings.mic"))
        add(wrapping("settings.mic.help"))
        add(micLabel)
        installButton.target = self
        installButton.action = #selector(install)
        installButton.bezelStyle = .rounded
        add(installButton)
        add(installLabel)

        add(gap())
        add(header("settings.while"))
        allowButton.title = NSLocalizedString("settings.allow", comment: "")
        allowButton.target = self
        allowButton.action = #selector(allowChanged)
        add(allowButton)
        add(wrapping("settings.allow.help"))

        add(gap())
        add(header("settings.login"))
        add(wrapping("settings.login.help"))
        loginButton.title = NSLocalizedString("settings.login.toggle", comment: "")
        loginButton.target = self
        loginButton.action = #selector(loginChanged)
        add(loginButton)
        track(loginLabel)
        add(loginLabel)
        let openLogin = NSButton(title: NSLocalizedString("settings.login.open", comment: ""), target: self, action: #selector(openLoginSettings))
        openLogin.bezelStyle = .rounded
        add(openLogin)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
    }

    private func track(_ label: NSTextField) {
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 440
        wrappingLabels.append(label)
    }

    private func fieldLabel(_ key: String) -> NSTextField {
        NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
    }

    private func header(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func wrapping(_ key: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: NSLocalizedString(key, comment: ""))
        field.preferredMaxLayoutWidth = 440
        wrappingLabels.append(field)
        return field
    }

    private func gap() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return view
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: NSLocalizedString(key, comment: ""), target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func permissionLine(_ key: String, granted: Bool) -> String {
        let state = granted
            ? NSLocalizedString("settings.granted", comment: "")
            : NSLocalizedString("settings.notGranted", comment: "")
        return NSLocalizedString(key, comment: "") + ": " + state
    }

    private func installText() -> String {
        if model.virtualMic.bundleMissing {
            return NSLocalizedString("settings.install.missingBundle", comment: "")
        }
        if let error = model.virtualMic.installError {
            return String(format: NSLocalizedString("settings.install.failed", comment: ""), error)
        }
        if model.virtualMic.installed {
            return NSLocalizedString("settings.install.ok", comment: "")
        }
        if model.virtualMic.installing {
            return NSLocalizedString("settings.installing", comment: "")
        }
        return ""
    }

    private func syncPopup(_ popup: NSPopUpButton, raw: String) {
        for item in popup.itemArray {
            if (item.representedObject as? String) == raw {
                if popup.selectedItem !== item {
                    popup.select(item)
                }
                return
            }
        }
    }

    private func rebuildDevicesIfNeeded() {
        let signature = model.discovered.map { "\($0.address)\t\($0.name)" }.joined(separator: "\n")
        let selected = devicePopup.selectedItem?.representedObject as? String
        if signature == deviceSignature && devicePopup.numberOfItems > 0 {
            return
        }
        deviceSignature = signature
        devicePopup.removeAllItems()
        if model.discovered.isEmpty {
            devicePopup.addItem(withTitle: NSLocalizedString("settings.devices.none", comment: ""))
            devicePopup.lastItem?.representedObject = nil
            pairButton.isEnabled = false
            return
        }
        for device in model.discovered {
            let mark = device.nameLooksLikeRemote ? "● " : ""
            devicePopup.addItem(withTitle: "\(mark)\(device.name)  \(device.address)")
            devicePopup.lastItem?.representedObject = device.address
        }
        if let selected, let match = devicePopup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            devicePopup.select(match)
        } else if let match = model.discovered.first(where: { $0.nameLooksLikeRemote }) {
            devicePopup.selectItem(withTitle: devicePopup.itemArray.first(where: { ($0.representedObject as? String) == match.address })?.title ?? "")
        }
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
    }

    private func relayout(scrollToTop: Bool) {
        guard let content = window?.contentView, let document = scroll.documentView else { return }
        let width = max(content.bounds.width, 420)
        let inner = width - 32
        for label in wrappingLabels {
            label.preferredMaxLayoutWidth = inner
        }
        let height = stack.fittingSize.height
        let docHeight = max(height + 32, scroll.contentView.bounds.height)
        let sizeChanged = abs(docHeight - lastDocHeight) > 1 || abs(document.frame.width - width) > 1
        if sizeChanged || scrollToTop {
            lastDocHeight = docHeight
            stack.frame = NSRect(x: 16, y: docHeight - height - 16, width: inner, height: height)
            document.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
        }
        if scrollToTop {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, docHeight - clip.bounds.height)))
            didScrollToTop = true
        }
    }

    @objc private func search() {
        model.search()
    }

    @objc private func deviceChanged() {
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
    }

    @objc private func pair() {
        guard let address = devicePopup.selectedItem?.representedObject as? String else { return }
        model.pair(address: address)
    }

    @objc private func reconnect() {
        model.reconnectNow()
    }

    @objc private func openBluetooth() {
        let candidates = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.settings.Bluetooth"
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func engineChanged() {
        let raw = enginePopup.selectedItem?.representedObject as? String ?? ""
        model.preferences.engine = Preferences.Engine(rawValue: raw) ?? .doubao
        refresh()
    }

    @objc private func keyChanged() {
        let raw = keyPopup.selectedItem?.representedObject as? String ?? ""
        model.preferences.talkKey = Preferences.TalkKey(rawValue: raw) ?? .fn
        refresh()
    }

    @objc private func restoreChanged() {
        model.preferences.restorePreviousInputSource = restoreButton.state == .on
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard let rawID = sender.identifier?.rawValue, let button = RemoteButton(rawValue: rawID) else { return }
        let raw = sender.selectedItem?.representedObject as? String ?? ""
        model.preferences.setAction(MappedAction(rawValue: raw) ?? .none, for: button)
    }

    @objc private func allowChanged() {
        model.preferences.allowControlsWhileSpeaking = allowButton.state == .on
        model.refreshControlGate()
    }

    @objc private func loginChanged() {
        model.setLaunchAtLogin(loginButton.state == .on)
    }

    @objc private func openLoginSettings() {
        LoginItem.openSettings()
    }

    @objc private func requestAccess() {
        Permissions.requestAccessibility()
        refresh()
    }

    @objc private func requestInput() {
        Permissions.requestInputMonitoring()
        refresh()
    }

    @objc private func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] in
            self?.model.macMic.refresh()
            self?.refresh()
        }
    }

    @objc private func install() {
        model.virtualMic.install()
    }
}
