import AppKit

/// A2854 front: aluminum body, power, clickpad, Back, TV, play/pause,
/// volume rocker, mute. Siri is the right-edge nub, not a front mic.
final class RemoteKeysView: NSView {
    var onOpenTouch: (() -> Void)?
    var onMappingChanged: (() -> Void)?

    private let illustration = A2854IllustrationView()
    private let powerLabel = SettingsChrome.locked("")
    private let touchButton = NSButton()
    private let siriLabel = SettingsChrome.locked("")
    private let backPopup = SettingsChrome.compactPopup()
    private let homePopup = SettingsChrome.compactPopup()
    private let playPopup = SettingsChrome.compactPopup()
    private let mutePopup = SettingsChrome.compactPopup()
    private let volumeButton = SettingsChrome.pillButton("")
    private var preferences: Preferences?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        illustration.translatesAutoresizingMaskIntoConstraints = false
        addSubview(illustration)
        let powerRow = labeled(SettingsChrome.L("settings.keys.power"), accessory: powerLabel)
        touchButton.bezelStyle = .recessed
        touchButton.controlSize = .small
        touchButton.font = .systemFont(ofSize: 12, weight: .medium)
        touchButton.target = self
        touchButton.action = #selector(openTouch)
        let touchRow = labeled(SettingsChrome.L("settings.keys.clickpad"), accessory: touchButton)
        let siriRow = labeled(SettingsChrome.L("control.siri"), accessory: siriLabel)

        SettingsChrome.fillActions(backPopup)
        SettingsChrome.fillActions(homePopup)
        SettingsChrome.fillActions(playPopup)
        SettingsChrome.fillActions(mutePopup)
        for popup in [backPopup, homePopup, playPopup, mutePopup] {
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 118).isActive = true
        }
        backPopup.target = self
        backPopup.action = #selector(changedBack)
        homePopup.target = self
        homePopup.action = #selector(changedHome)
        playPopup.target = self
        playPopup.action = #selector(changedPlay)
        mutePopup.target = self
        mutePopup.action = #selector(changedMute)

        let backHome = NSStackView(views: [
            mini(SettingsChrome.L("settings.keys.back"), backPopup),
            mini(SettingsChrome.L("settings.keys.home"), homePopup)
        ])
        backHome.orientation = .horizontal
        backHome.spacing = 10
        backHome.alignment = .centerY

        volumeButton.target = self
        volumeButton.action = #selector(showVolumeMenu(_:))
        volumeButton.title = SettingsChrome.L("settings.keys.volume.pair")

        let playRow = labeled(SettingsChrome.L("settings.keys.play"), accessory: playPopup)
        let muteVol = NSStackView(views: [
            mini(SettingsChrome.L("settings.keys.mute"), mutePopup),
            mini(SettingsChrome.L("settings.keys.volume"), volumeButton)
        ])
        muteVol.orientation = .horizontal
        muteVol.spacing = 10
        muteVol.alignment = .centerY

        let callouts = NSStackView(views: [powerRow, touchRow, siriRow, backHome, playRow, muteVol])
        callouts.orientation = .vertical
        callouts.alignment = .leading
        callouts.spacing = 14
        callouts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(callouts)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 348),
            illustration.leadingAnchor.constraint(equalTo: leadingAnchor),
            illustration.topAnchor.constraint(equalTo: topAnchor),
            illustration.bottomAnchor.constraint(equalTo: bottomAnchor),
            illustration.widthAnchor.constraint(equalToConstant: 148),
            callouts.leadingAnchor.constraint(equalTo: illustration.trailingAnchor, constant: 12),
            callouts.trailingAnchor.constraint(equalTo: trailingAnchor),
            callouts.centerYAnchor.constraint(equalTo: illustration.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh(preferences: Preferences) {
        self.preferences = preferences
        powerLabel.stringValue = SettingsChrome.L("settings.keys.power.map")
        touchButton.title = SettingsChrome.L("settings.keys.clickpad.map")
        siriLabel.stringValue = SettingsChrome.L("settings.keys.siri.map")
        SettingsChrome.select(backPopup, raw: preferences.action(for: .back).rawValue)
        SettingsChrome.select(homePopup, raw: preferences.action(for: .home).rawValue)
        SettingsChrome.select(playPopup, raw: preferences.action(for: .play).rawValue)
        SettingsChrome.select(mutePopup, raw: preferences.action(for: .mute).rawValue)
        let up = preferences.action(for: .volumeUp)
        let down = preferences.action(for: .volumeDown)
        if up == .volumeUp && down == .volumeDown {
            volumeButton.title = SettingsChrome.L("settings.keys.volume.pair")
        } else {
            volumeButton.title = SettingsChrome.L(up.titleKey) + " / " + SettingsChrome.L(down.titleKey)
        }
    }

    private func labeled(_ title: String, accessory: NSView) -> NSStackView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, accessory])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func mini(_ title: String, _ accessory: NSView) -> NSStackView {
        labeled(title, accessory: accessory)
    }

    private func volumeMenu() -> NSMenu {
        let menu = NSMenu()
        let pair = NSMenuItem(title: SettingsChrome.L("settings.keys.volume.pair"), action: #selector(resetVolume), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)
        menu.addItem(.separator())
        let upHeader = NSMenuItem(title: SettingsChrome.L("control.volumeUp"), action: nil, keyEquivalent: "")
        upHeader.isEnabled = false
        menu.addItem(upHeader)
        for action in MappedAction.allCases {
            let item = NSMenuItem(title: SettingsChrome.L(action.titleKey), action: #selector(pickVolumeUp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.indentationLevel = 1
            if let preferences, preferences.action(for: .volumeUp) == action {
                item.state = .on
            }
            menu.addItem(item)
        }
        let downHeader = NSMenuItem(title: SettingsChrome.L("control.volumeDown"), action: nil, keyEquivalent: "")
        downHeader.isEnabled = false
        menu.addItem(downHeader)
        for action in MappedAction.allCases {
            let item = NSMenuItem(title: SettingsChrome.L(action.titleKey), action: #selector(pickVolumeDown(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.indentationLevel = 1
            if let preferences, preferences.action(for: .volumeDown) == action {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showVolumeMenu(_ sender: NSButton) {
        let menu = volumeMenu()
        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    private func set(_ button: RemoteButton, from popup: NSPopUpButton) {
        let raw = popup.selectedItem?.representedObject as? String ?? ""
        preferences?.setAction(MappedAction(rawValue: raw) ?? .none, for: button)
        onMappingChanged?()
    }

    @objc private func changedBack() { set(.back, from: backPopup) }
    @objc private func changedHome() { set(.home, from: homePopup) }
    @objc private func changedPlay() { set(.play, from: playPopup) }
    @objc private func changedMute() { set(.mute, from: mutePopup) }

    @objc private func resetVolume() {
        preferences?.setAction(.volumeUp, for: .volumeUp)
        preferences?.setAction(.volumeDown, for: .volumeDown)
        if let preferences { refresh(preferences: preferences) }
        onMappingChanged?()
    }

    @objc private func pickVolumeUp(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        preferences?.setAction(MappedAction(rawValue: raw) ?? .volumeUp, for: .volumeUp)
        if let preferences { refresh(preferences: preferences) }
        onMappingChanged?()
    }

    @objc private func pickVolumeDown(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        preferences?.setAction(MappedAction(rawValue: raw) ?? .volumeDown, for: .volumeDown)
        if let preferences { refresh(preferences: preferences) }
        onMappingChanged?()
    }

    @objc private func openTouch() {
        onOpenTouch?()
    }
}

private final class A2854IllustrationView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 348) }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 28, y: 4, width: 88, height: 340)
        let path = NSBezierPath(roundedRect: body, xRadius: 16, yRadius: 16)
        NSGradient(
            colors: [
                NSColor(calibratedWhite: 0.93, alpha: 1),
                NSColor(calibratedWhite: 0.78, alpha: 1),
                NSColor(calibratedWhite: 0.86, alpha: 1)
            ]
        )?.draw(in: path, angle: 80)
        NSColor(calibratedWhite: 0.62, alpha: 0.7).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Siri right-edge nub — not a front microphone.
        let nub = NSRect(x: body.maxX - 3, y: 72, width: 9, height: 26)
        let nubPath = NSBezierPath(roundedRect: nub, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
        nubPath.fill()
        NSColor(calibratedWhite: 0.5, alpha: 0.8).setStroke()
        nubPath.lineWidth = 0.8
        nubPath.stroke()

        // LED + power
        let led = NSRect(x: body.maxX - 34, y: 20, width: 6, height: 6)
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: led).fill()
        let power = NSRect(x: body.maxX - 24, y: 16, width: 14, height: 14)
        NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: power).fill()
        drawSymbol("power", in: power.insetBy(dx: 2.2, dy: 2.2), color: .white)

        // Clickpad
        let pad = NSRect(x: body.midX - 30, y: 44, width: 60, height: 60)
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(ovalIn: pad).fill()
        NSColor(calibratedWhite: 0.22, alpha: 1).setStroke()
        let padStroke = NSBezierPath(ovalIn: pad)
        padStroke.lineWidth = 1
        padStroke.stroke()
        let dots: [CGPoint] = [
            CGPoint(x: pad.midX, y: pad.minY + 10),
            CGPoint(x: pad.maxX - 10, y: pad.midY),
            CGPoint(x: pad.midX, y: pad.maxY - 10),
            CGPoint(x: pad.minX + 10, y: pad.midY)
        ]
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        for point in dots {
            NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        }

        // Back / TV
        let back = NSRect(x: body.minX + 14, y: 118, width: 26, height: 26)
        let tv = NSRect(x: body.maxX - 40, y: 118, width: 26, height: 26)
        fillButton(back)
        fillButton(tv)
        drawSymbol("chevron.backward", in: back.insetBy(dx: 5, dy: 5), color: .white)
        drawSymbol("tv", in: tv.insetBy(dx: 5, dy: 5), color: .white)

        // Play / volume+
        let play = NSRect(x: body.minX + 14, y: 154, width: 26, height: 26)
        let volUp = NSRect(x: body.maxX - 40, y: 154, width: 26, height: 26)
        fillButton(play)
        fillRocker(volUp, connectedDown: true)
        drawSymbol("playpause.fill", in: play.insetBy(dx: 5, dy: 6), color: .white)
        drawSymbol("plus", in: volUp.insetBy(dx: 6, dy: 6), color: .white)

        // Mute / volume−
        let mute = NSRect(x: body.minX + 14, y: 188, width: 26, height: 26)
        let volDown = NSRect(x: body.maxX - 40, y: 188, width: 26, height: 26)
        fillButton(mute)
        fillRocker(volDown, connectedDown: false)
        drawSymbol("speaker.slash.fill", in: mute.insetBy(dx: 5, dy: 6), color: .white)
        drawSymbol("minus", in: volDown.insetBy(dx: 6, dy: 6), color: .white)

        // USB-C
        let usb = NSRect(x: body.midX - 10, y: body.maxY - 18, width: 20, height: 5)
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: usb, xRadius: 2, yRadius: 2).fill()
    }

    private func fillButton(_ rect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func fillRocker(_ rect: NSRect, connectedDown: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: connectedDown ? 8 : 8, yRadius: 8)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        path.fill()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: min(rect.width, rect.height), weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return
        }
        image.isTemplate = true
        color.set()
        var draw = rect
        let size = image.size
        if size.width > 0 {
            let scale = min(rect.width / size.width, rect.height / size.height)
            draw.size = NSSize(width: size.width * scale, height: size.height * scale)
            draw.origin.x = rect.midX - draw.width / 2
            draw.origin.y = rect.midY - draw.height / 2
        }
        image.draw(in: draw, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
