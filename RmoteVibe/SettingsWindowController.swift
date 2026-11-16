import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let model: AppModel
    private var currentPage: SettingsPage = .general
    private var sidebarItems: [SidebarItemView] = []
    private let pagesHost = NSView()
    private var pageViews: [SettingsPage: NSView] = [:]
    private let searchField = NSSearchField()

    private let loginSwitch = NSSwitch()
    private let loginCaption = SettingsChrome.caption("")
    private let languagePopup = SettingsChrome.compactPopup()

    private let remotePill = StatusPill()
    private let remoteDevice = SettingsChrome.locked("")
    private let remoteAddress = SettingsChrome.locked("")
    private let remoteCaption = SettingsChrome.caption("")
    private let reconnectButton = SettingsChrome.pillButton("")
    private let bluetoothButton = SettingsChrome.pillButton("")
    private let searchButton = SettingsChrome.pillButton("")
    private let pairButton = SettingsChrome.pillButton("")
    private let devicePopup = NSPopUpButton()
    private var deviceSignature = ""

    private let keysView = RemoteKeysView()
    private let keysFooter = SettingsChrome.caption("")

    private let pointerPopup = SettingsChrome.compactPopup()
    private let gainSlider = NSSlider()
    private let gainValue = SettingsChrome.locked("680")
    private let touchStatus = SettingsChrome.caption("")

    private let enginePopup = SettingsChrome.compactPopup()
    private let keyPopup = SettingsChrome.compactPopup()
    private let sourceLocked = SettingsChrome.locked("")
    private let micStatus = SettingsChrome.locked("")
    private let allowSwitch = NSSwitch()
    private let restoreSwitch = NSSwitch()
    private let installButton = SettingsChrome.pillButton("")
    private let voiceFooter = SettingsChrome.caption("")

    private let accessStatus = SettingsChrome.locked("")
    private let inputStatus = SettingsChrome.locked("")
    private let micPermStatus = SettingsChrome.locked("")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsChrome.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 500)
        window.setContentSize(SettingsChrome.windowSize)
        window.title = SettingsChrome.L("settings.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        super.init(window: window)
        window.delegate = self
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect)
        bluetoothButton.target = self
        bluetoothButton.action = #selector(openBluetooth)
        searchButton.target = self
        searchButton.action = #selector(search)
        pairButton.target = self
        pairButton.action = #selector(pairSelected)
        installButton.target = self
        installButton.action = #selector(install)
        build()
        refresh()
        showPage(Self.launchPage())
    }

    private static func launchPage() -> SettingsPage {
        guard let index = CommandLine.arguments.firstIndex(of: "--settings-page"),
              index + 1 < CommandLine.arguments.count,
              let page = SettingsPage(rawValue: CommandLine.arguments[index + 1]) else {
            return .general
        }
        return page
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refresh()
    }

    func refresh() {
        guard window != nil else { return }
        loginSwitch.state = model.preferences.launchAtLogin ? .on : .off
        loginCaption.stringValue = model.loginStatus

        switch model.remoteStatusKind() {
        case .connected:
            remotePill.set(text: SettingsChrome.L("settings.remote.connected"), connected: true)
        case .reconnecting:
            remotePill.set(text: SettingsChrome.L("settings.remote.reconnecting"), connected: false)
        case .pairedIdle:
            remotePill.set(text: SettingsChrome.L("settings.remote.pairedIdle"), connected: false)
        case .disconnected:
            remotePill.set(text: SettingsChrome.L("settings.remote.disconnected"), connected: false)
        }
        remoteDevice.stringValue = model.remoteDeviceDisplay()
        remoteAddress.stringValue = model.remoteAddressDisplay()
        remoteCaption.stringValue = model.pairMessage?.isEmpty == false
            ? (model.pairMessage ?? "")
            : SettingsChrome.L("settings.remote.pair.footer")
        reconnectButton.title = model.reconnecting
            ? SettingsChrome.L("settings.reconnecting")
            : SettingsChrome.L("settings.remote.reconnect.button")
        reconnectButton.isEnabled = !model.remote.isConnected && !model.pairing
        bluetoothButton.title = SettingsChrome.L("settings.remote.bluetooth.button")
        searchButton.title = model.searching
            ? SettingsChrome.L("settings.searching")
            : SettingsChrome.L("settings.search")
        searchButton.isEnabled = !model.searching
        pairButton.title = SettingsChrome.L("settings.pair")
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
        rebuildDevicesIfNeeded()

        keysView.refresh(preferences: model.preferences)

        touchStatus.stringValue = model.touch.statusText
        gainSlider.doubleValue = 680
        gainValue.stringValue = "680"

        SettingsChrome.select(enginePopup, raw: model.preferences.engine.rawValue)
        SettingsChrome.select(keyPopup, raw: model.preferences.talkKey.rawValue)
        sourceLocked.stringValue = SettingsChrome.L("settings.voice.doubaoAuto")
        if model.virtualMic.installed {
            micStatus.stringValue = SettingsChrome.L("settings.voice.mic.visible")
        } else if model.virtualMic.installing {
            micStatus.stringValue = SettingsChrome.L("settings.installing")
        } else {
            micStatus.stringValue = SettingsChrome.L("settings.voice.mic.missing")
        }
        allowSwitch.state = model.preferences.allowControlsWhileSpeaking ? .on : .off
        restoreSwitch.state = model.preferences.restorePreviousInputSource ? .on : .off
        installButton.title = model.virtualMic.installing
            ? SettingsChrome.L("settings.installing")
            : SettingsChrome.L("settings.install")
        installButton.isEnabled = !model.virtualMic.installing
        installButton.isHidden = model.virtualMic.installed && model.virtualMic.installError == nil
        voiceFooter.stringValue = installText()

        accessStatus.stringValue = permissionState(Permissions.accessibility)
        inputStatus.stringValue = permissionState(Permissions.inputMonitoring)
        micPermStatus.stringValue = permissionState(Permissions.microphone)
    }

    private func build() {
        guard let window else { return }
        let root = SettingsChrome.visualEffect(.underWindowBackground)
        window.contentView = root

        let sidebar = SettingsChrome.visualEffect(.sidebar)
        sidebar.wantsLayer = true
        root.addSubview(sidebar)

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        root.addSubview(divider)

        pagesHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pagesHost)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsChrome.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            pagesHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pagesHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pagesHost.topAnchor.constraint(equalTo: root.topAnchor),
            pagesHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        buildSidebar(sidebar)
        pageViews = [
            .general: wrap(buildGeneral()),
            .remote: wrap(buildRemote()),
            .keys: wrap(buildKeys()),
            .touch: wrap(buildTouch()),
            .voice: wrap(buildVoice()),
            .permissions: wrap(buildPermissions())
        ]
        for view in pageViews.values {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
    }

    private func buildSidebar(_ sidebar: NSView) {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 8
        icon.layer?.masksToBounds = true

        let name = SettingsChrome.title(SettingsChrome.L("settings.title"), size: 13, weight: .semibold)
        let role = SettingsChrome.caption(SettingsChrome.L("settings.sidebar.role"))
        let identity = NSStackView(views: [name, role])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1
        identity.translatesAutoresizingMaskIntoConstraints = false

        let brand = NSStackView(views: [icon, identity])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 8
        brand.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = SettingsChrome.L("settings.sidebar.search")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        for page in SettingsPage.allCases {
            let item = SidebarItemView(page: page)
            item.onSelect = { [weak self] selected in self?.showPage(selected) }
            sidebarItems.append(item)
            nav.addArrangedSubview(item)
            item.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
            item.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
        }

        sidebar.addSubview(brand)
        sidebar.addSubview(searchField)
        sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            brand.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 42),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 14),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            nav.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12)
        ])
    }

    private func wrap(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: SettingsChrome.pageInset),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -SettingsChrome.pageInset),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor, constant: -(SettingsChrome.pageInset * 2))
        ])
        return scroll
    }

    private func buildGeneral() -> NSView {
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        loginSwitch.controlSize = .small
        languagePopup.removeAllItems()
        languagePopup.addItem(withTitle: SettingsChrome.L("settings.general.followSystem"))
        languagePopup.isEnabled = false

        let start = SettingsGroupView()
        start.addRow(title: SettingsChrome.L("settings.login.toggle"), accessory: loginSwitch)
        let language = SettingsGroupView()
        language.addRow(title: SettingsChrome.L("settings.general.uiLanguage"), accessory: languagePopup)
        let behavior = SettingsGroupView()
        behavior.addRow(title: SettingsChrome.L("settings.general.menubar"), accessory: SettingsChrome.locked(SettingsChrome.L("settings.general.menubar.on")))
        behavior.addRow(title: SettingsChrome.L("settings.general.siri"), accessory: SettingsChrome.locked(SettingsChrome.L("settings.general.siri.locked")))

        let labeledStart = labeledGroup(SettingsChrome.L("settings.general.startup"), start, loginCaption)
        let labeledLanguage = labeledGroup(
            SettingsChrome.L("settings.general.language"),
            language,
            SettingsChrome.caption(SettingsChrome.L("settings.general.language.footer"))
        )
        let labeledBehavior = labeledGroup(
            SettingsChrome.L("settings.general.behavior"),
            behavior,
            SettingsChrome.caption(SettingsChrome.L("settings.general.behavior.footer"))
        )
        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.page.general"),
                subtitle: SettingsChrome.L("settings.general.subtitle")
            ),
            labeledStart,
            labeledLanguage,
            labeledBehavior
        ])
    }

    private func buildRemote() -> NSView {
        let status = SettingsGroupView()
        status.addRow(title: SettingsChrome.L("settings.remote.status"), accessory: remotePill)
        status.addRow(title: SettingsChrome.L("settings.remote.device"), accessory: remoteDevice)
        status.addRow(title: SettingsChrome.L("settings.remote.address"), accessory: remoteAddress)

        let actions = SettingsGroupView()
        actions.addRow(title: SettingsChrome.L("settings.remote.reconnect.row"), accessory: reconnectButton)
        actions.addRow(title: SettingsChrome.L("settings.remote.bluetooth.row"), accessory: bluetoothButton)

        devicePopup.bezelStyle = .rounded
        devicePopup.controlSize = .small
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        let pairRow = NSStackView(views: [devicePopup, searchButton, pairButton])
        pairRow.orientation = .horizontal
        pairRow.spacing = 8
        pairRow.alignment = .centerY
        let pairing = SettingsGroupView()
        pairing.addRow(title: SettingsChrome.L("settings.remote.pairing"), accessory: pairRow)

        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.remote"),
                subtitle: SettingsChrome.L("settings.remote.subtitle")
            ),
            labeledGroup(SettingsChrome.L("settings.remote.connection"), status, remoteCaption),
            actions,
            pairing
        ])
    }

    private func buildKeys() -> NSView {
        keysView.onOpenTouch = { [weak self] in self?.showPage(.touch) }
        keysFooter.stringValue = SettingsChrome.L("settings.keys.footer")
        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.buttons"),
                subtitle: SettingsChrome.L("settings.keys.subtitle")
            ),
            keysView,
            keysFooter
        ], spacing: 16)
    }

    private func buildTouch() -> NSView {
        pointerPopup.removeAllItems()
        pointerPopup.addItem(withTitle: SettingsChrome.L("settings.touch.relative"))
        pointerPopup.isEnabled = false
        gainSlider.minValue = 200
        gainSlider.maxValue = 1200
        gainSlider.doubleValue = 680
        gainSlider.isEnabled = false
        gainSlider.controlSize = .small
        gainSlider.translatesAutoresizingMaskIntoConstraints = false
        gainSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let gain = NSStackView(views: [gainSlider, gainValue])
        gain.orientation = .horizontal
        gain.spacing = 8
        gain.alignment = .centerY

        let surface = SettingsGroupView()
        surface.addRow(title: SettingsChrome.L("settings.touch.pointerMode"), accessory: pointerPopup)
        surface.addRow(title: SettingsChrome.L("settings.touch.gain"), accessory: gain)
        let gestures = SettingsGroupView()
        gestures.addRow(
            title: SettingsChrome.L("settings.touch.tap"),
            accessory: SettingsChrome.locked(SettingsChrome.L("settings.touch.click"))
        )
        gestures.addRow(
            title: SettingsChrome.L("settings.touch.edge"),
            accessory: SettingsChrome.locked(SettingsChrome.L("settings.touch.scroll"))
        )
        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.touch"),
                subtitle: SettingsChrome.L("settings.touch.subtitle")
            ),
            labeledGroup(
                SettingsChrome.L("settings.touch.surface"),
                surface,
                SettingsChrome.caption(SettingsChrome.L("settings.touch.surface.footer"))
            ),
            labeledGroup(
                "",
                gestures,
                SettingsChrome.caption(SettingsChrome.L("settings.touch.gestures.footer"))
            ),
            touchStatus
        ])
    }

    private func buildVoice() -> NSView {
        enginePopup.removeAllItems()
        enginePopup.addItem(withTitle: SettingsChrome.L("engine.doubao"))
        enginePopup.lastItem?.representedObject = Preferences.Engine.doubao.rawValue
        enginePopup.addItem(withTitle: SettingsChrome.L("engine.wechat"))
        enginePopup.lastItem?.representedObject = Preferences.Engine.wechat.rawValue
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        keyPopup.removeAllItems()
        keyPopup.addItem(withTitle: SettingsChrome.L("key.rightCommand"))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.rightCommand.rawValue
        keyPopup.addItem(withTitle: SettingsChrome.L("key.leftOption"))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.leftOption.rawValue
        keyPopup.addItem(withTitle: SettingsChrome.L("key.fn"))
        keyPopup.lastItem?.representedObject = Preferences.TalkKey.fn.rawValue
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)
        allowSwitch.target = self
        allowSwitch.action = #selector(allowChanged)
        allowSwitch.controlSize = .small
        restoreSwitch.target = self
        restoreSwitch.action = #selector(restoreChanged)
        restoreSwitch.controlSize = .small

        let engine = SettingsGroupView()
        engine.addRow(title: SettingsChrome.L("settings.voice.engine.row"), accessory: enginePopup)
        engine.addRow(title: SettingsChrome.L("settings.talkKey"), accessory: keyPopup)
        engine.addRow(title: SettingsChrome.L("settings.voice.doubaoSource"), accessory: sourceLocked)
        engine.addRow(title: SettingsChrome.L("settings.restore"), accessory: restoreSwitch)

        let micAccessory = NSStackView(views: [micStatus, installButton])
        micAccessory.orientation = .horizontal
        micAccessory.spacing = 8
        micAccessory.alignment = .centerY
        let mic = SettingsGroupView()
        mic.addRow(title: "RmoteVibe Mic", accessory: micAccessory)
        mic.addRow(title: SettingsChrome.L("settings.voice.allowTouch"), accessory: allowSwitch)

        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.voice"),
                subtitle: SettingsChrome.L("settings.voice.subtitle")
            ),
            labeledGroup(
                SettingsChrome.L("settings.voice.engine.group"),
                engine,
                SettingsChrome.caption(SettingsChrome.L("settings.voice.engine.footer"))
            ),
            labeledGroup(
                SettingsChrome.L("settings.voice.mic.group"),
                mic,
                SettingsChrome.caption(SettingsChrome.L("settings.voice.mic.footer"))
            ),
            voiceFooter
        ])
    }

    private func buildPermissions() -> NSView {
        let access = SettingsChrome.pillButton(SettingsChrome.L("settings.request"))
        access.target = self
        access.action = #selector(requestAccess)
        let input = SettingsChrome.pillButton(SettingsChrome.L("settings.request"))
        input.target = self
        input.action = #selector(requestInput)
        let mic = SettingsChrome.pillButton(SettingsChrome.L("settings.request"))
        mic.target = self
        mic.action = #selector(requestMicrophone)
        let group = SettingsGroupView()
        group.addRow(title: SettingsChrome.L("settings.accessibility"), accessory: accessoryPair(accessStatus, access))
        group.addRow(title: SettingsChrome.L("settings.input"), accessory: accessoryPair(inputStatus, input))
        group.addRow(title: SettingsChrome.L("settings.microphone"), accessory: accessoryPair(micPermStatus, mic))
        return SettingsChrome.column([
            SettingsChrome.pageHeader(
                title: SettingsChrome.L("settings.permissions"),
                subtitle: SettingsChrome.L("settings.perm.subtitle")
            ),
            labeledGroup("", group, SettingsChrome.caption(SettingsChrome.L("settings.perm.footer")))
        ])
    }

    private func accessoryPair(_ left: NSView, _ right: NSView) -> NSStackView {
        let stack = NSStackView(views: [left, right])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func labeledGroup(_ title: String, _ group: NSView, _ footer: NSView) -> NSView {
        var views: [NSView] = []
        if !title.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            views.append(label)
        }
        views.append(group)
        views.append(footer)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return stack
    }

    private func showPage(_ page: SettingsPage) {
        currentPage = page
        for item in sidebarItems {
            item.setSelected(item.page == page)
        }
        for view in pagesHost.subviews {
            view.removeFromSuperview()
        }
        if let view = pageViews[page] {
            pagesHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pagesHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pagesHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: pagesHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: pagesHost.bottomAnchor)
            ])
        }
        window?.setContentSize(SettingsChrome.windowSize)
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var firstVisible: SettingsPage?
        for item in sidebarItems {
            let title = SettingsChrome.L(item.page.titleKey).lowercased()
            let visible = query.isEmpty || title.contains(query)
            item.isHidden = !visible
            if visible && firstVisible == nil {
                firstVisible = item.page
            }
        }
        if pageViews[currentPage]?.isHidden == true || sidebarItems.first(where: { $0.page == currentPage })?.isHidden == true {
            if let firstVisible {
                showPage(firstVisible)
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
            devicePopup.addItem(withTitle: SettingsChrome.L("settings.devices.none"))
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
            if let item = devicePopup.itemArray.first(where: { ($0.representedObject as? String) == match.address }) {
                devicePopup.select(item)
            }
        }
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
    }

    private func permissionState(_ granted: Bool) -> String {
        granted ? SettingsChrome.L("settings.granted") : SettingsChrome.L("settings.notGranted")
    }

    private func installText() -> String {
        if model.virtualMic.bundleMissing {
            return SettingsChrome.L("settings.install.missingBundle")
        }
        if let error = model.virtualMic.installError {
            return String(format: SettingsChrome.L("settings.install.failed"), error)
        }
        return ""
    }

    @objc private func search() { model.search() }
    @objc private func deviceChanged() {
        pairButton.isEnabled = !model.pairing && devicePopup.selectedItem?.representedObject != nil
    }
    @objc private func pairSelected() {
        guard let address = devicePopup.selectedItem?.representedObject as? String else { return }
        model.pair(address: address)
    }
    @objc private func reconnect() { model.reconnectNow() }
    @objc private func openBluetooth() {
        let candidates = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.settings.Bluetooth"
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
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
        model.preferences.restorePreviousInputSource = restoreSwitch.state == .on
    }
    @objc private func allowChanged() {
        model.preferences.allowControlsWhileSpeaking = allowSwitch.state == .on
        model.refreshControlGate()
    }
    @objc private func loginChanged() {
        model.setLaunchAtLogin(loginSwitch.state == .on)
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
