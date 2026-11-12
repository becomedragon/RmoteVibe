import AppKit
import CoreGraphics
import Foundation

/// Buttons the settings panel can assign. Siri and the click-ring center are not here.
enum RemoteButton: String, CaseIterable {
    case back
    case play
    case mute
    case volumeUp
    case volumeDown
    case home

    var usage: (UInt32, UInt32) {
        switch self {
        case .back: return (0x01, 0x86)
        case .play: return (0x0C, 0xCD)
        case .mute: return (0x0C, 0xE2)
        case .volumeUp: return (0x0C, 0xE9)
        case .volumeDown: return (0x0C, 0xEA)
        case .home: return (0x0C, 0x60)
        }
    }

    var titleKey: String {
        switch self {
        case .back: return "control.back"
        case .play: return "control.play"
        case .mute: return "control.mute"
        case .volumeUp: return "control.volumeUp"
        case .volumeDown: return "control.volumeDown"
        case .home: return "control.home"
        }
    }

    static func match(page: UInt32, usage: UInt32) -> RemoteButton? {
        allCases.first { $0.usage == (page, usage) }
    }
}

enum MappedAction: String, CaseIterable {
    case none
    case leftClick
    case rightClick
    case middleClick
    case scrollUp
    case scrollDown
    case scrollLeft
    case scrollRight
    case missionControl
    case showDesktop
    case spotlight
    case launchpad
    case mediaPlayPause
    case mediaNext
    case mediaPrevious
    case volumeUp
    case volumeDown
    case volumeMute
    case escape
    case returnKey = "return"

    var titleKey: String { "action." + rawValue }

    /// Posts one action. Shortcut names are the system defaults, not a promise
    /// that the user still has those shortcuts.
    func perform() -> Bool {
        guard self != .none else { return true }
        guard Permissions.accessibility else { return false }
        switch self {
        case .none:
            return true
        case .leftClick:
            ButtonEvents.click(.left, down: .leftMouseDown, up: .leftMouseUp)
        case .rightClick:
            ButtonEvents.click(.right, down: .rightMouseDown, up: .rightMouseUp)
        case .middleClick:
            ButtonEvents.click(.center, down: .otherMouseDown, up: .otherMouseUp)
        case .scrollUp:
            ButtonEvents.scroll(vertical: 3, horizontal: 0)
        case .scrollDown:
            ButtonEvents.scroll(vertical: -3, horizontal: 0)
        case .scrollLeft:
            ButtonEvents.scroll(vertical: 0, horizontal: -3)
        case .scrollRight:
            ButtonEvents.scroll(vertical: 0, horizontal: 3)
        case .missionControl:
            ButtonEvents.key(126, flags: .maskControl)
        case .showDesktop:
            ButtonEvents.key(103, flags: [])
        case .spotlight:
            ButtonEvents.key(49, flags: .maskCommand)
        case .launchpad:
            ButtonEvents.key(118, flags: [])
        case .mediaPlayPause:
            ButtonEvents.media(16)
        case .mediaNext:
            ButtonEvents.media(17)
        case .mediaPrevious:
            ButtonEvents.media(18)
        case .volumeUp:
            ButtonEvents.media(0)
        case .volumeDown:
            ButtonEvents.media(1)
        case .volumeMute:
            ButtonEvents.media(7)
        case .escape:
            ButtonEvents.key(53, flags: [])
        case .returnKey:
            ButtonEvents.key(0x24, flags: [])
        }
        return true
    }
}

private enum ButtonEvents {
    static func click(_ button: CGMouseButton, down: CGEventType, up: CGEventType) {
        guard let point = CGEvent(source: nil)?.location else { return }
        post(down, at: point, button: button)
        post(up, at: point, button: button)
    }

    static func scroll(vertical: Int32, horizontal: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// System-defined media key. Hardware volume and play are suppressed separately.
    static func media(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}
