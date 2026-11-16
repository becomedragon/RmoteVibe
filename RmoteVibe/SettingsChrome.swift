import AppKit

enum SettingsPage: String, CaseIterable {
    case general
    case remote
    case keys
    case touch
    case voice
    case permissions

    var titleKey: String {
        switch self {
        case .general: return "settings.page.general"
        case .remote: return "settings.remote"
        case .keys: return "settings.buttons"
        case .touch: return "settings.touch"
        case .voice: return "settings.voice"
        case .permissions: return "settings.permissions"
        }
    }
}

enum SettingsChrome {
    static let windowSize = NSSize(width: 720, height: 560)
    static let sidebarWidth: CGFloat = 198
    static let pageInset: CGFloat = 28
    static let groupRadius: CGFloat = 10
    static let rowHeight: CGFloat = 36

    static func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func visualEffect(_ material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    static func glassCard() -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = groupRadius
        glass.style = .regular
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    static func title(_ text: String, size: CGFloat = 22, weight: NSFont.Weight = .semibold) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 4
        return field
    }

    static func locked(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    static func pillButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    static func compactPopup() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12, weight: .medium)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        return popup
    }

    static func fillActions(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for action in MappedAction.allCases {
            popup.addItem(withTitle: L(action.titleKey))
            popup.lastItem?.representedObject = action.rawValue
        }
    }

    static func select(_ popup: NSPopUpButton, raw: String) {
        for item in popup.itemArray where (item.representedObject as? String) == raw {
            if popup.selectedItem !== item {
                popup.select(item)
            }
            return
        }
    }

    static func pageHeader(title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView(views: [
            self.title(title),
            caption(subtitle)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return stack
    }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class SettingsGroupView: NSView {
    private let stack = NSStackView()
    private var rows: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsChrome.groupRadius
        layer?.cornerCurve = .continuous
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let glass = SettingsChrome.glassCard()
        addSubview(glass)
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(stack)
        glass.contentView = inner
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: inner.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -2),
            inner.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func addRow(title: String, accessory: NSView) {
        if !rows.isEmpty {
            stack.addArrangedSubview(Self.separator())
        }
        let row = SettingsRowView(title: title, accessory: accessory)
        rows.append(row)
        stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private static func separator() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 1)
        ])
        return box
    }
}

final class SettingsRowView: NSView {
    init(title: String, accessory: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(accessory)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsChrome.rowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class StatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(text: String, connected: Bool) {
        label.stringValue = text
        let color: NSColor = connected ? .systemGreen : .systemOrange
        dot.layer?.backgroundColor = color.cgColor
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        label.textColor = color
    }
}

final class SidebarItemView: NSView {
    let page: SettingsPage
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()
    var onSelect: ((SettingsPage) -> Void)?
    private(set) var isSelected = false

    init(page: SettingsPage) {
        self.page = page
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        label.stringValue = SettingsChrome.L(page.titleKey)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(SettingsChrome.L(page.titleKey))
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        highlight.layer?.backgroundColor = selected
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(page)
    }

    override func updateLayer() {
        super.updateLayer()
        setSelected(isSelected)
    }
}
