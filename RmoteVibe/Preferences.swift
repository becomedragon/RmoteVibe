import Foundation

final class Preferences {
    enum Engine: String {
        case doubao
        case wechat
    }

    enum TalkKey: String {
        case rightCommand
        case leftOption
        case fn
    }

    private let defaults = UserDefaults.standard

    var engine: Engine {
        get { Engine(rawValue: defaults.string(forKey: "voiceEngine") ?? "") ?? .doubao }
        set { defaults.set(newValue.rawValue, forKey: "voiceEngine") }
    }

    var talkKey: TalkKey {
        get { TalkKey(rawValue: defaults.string(forKey: "talkKey") ?? "") ?? .fn }
        set { defaults.set(newValue.rawValue, forKey: "talkKey") }
    }

    /// Last remote this Mac paired. Reconnect uses this address when set.
    /// Empty until the user pairs a Siri Remote. Serial number is not required.
    var pairedAddress: String {
        get { defaults.string(forKey: "pairedAddress") ?? "" }
        set { defaults.set(newValue, forKey: "pairedAddress") }
    }

    /// On when the key has never been set. SMAppService registration follows this.
    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: "launchAtLogin") == nil {
                return true
            }
            return defaults.bool(forKey: "launchAtLogin")
        }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    /// Off by default. Pointer, scroll, drag, and other buttons stay off while Siri is held.
    var allowControlsWhileSpeaking: Bool {
        get { defaults.bool(forKey: "allowControlsWhileSpeaking") }
        set { defaults.set(newValue, forKey: "allowControlsWhileSpeaking") }
    }

    /// Off by default. Restoring the previous input source too soon can cut the
    /// input method off before it commits. The delay is not measured.
    var restorePreviousInputSource: Bool {
        get { defaults.bool(forKey: "restorePreviousInputSource") }
        set { defaults.set(newValue, forKey: "restorePreviousInputSource") }
    }

    func action(for button: RemoteButton) -> MappedAction {
        let stored = defaults.dictionary(forKey: "buttonActions") as? [String: String]
        if let raw = stored?[button.rawValue], let action = MappedAction(rawValue: raw) {
            return action
        }
        return Self.fallbackActions[button] ?? .none
    }

    func setAction(_ action: MappedAction, for button: RemoteButton) {
        var stored = defaults.dictionary(forKey: "buttonActions") as? [String: String] ?? [:]
        stored[button.rawValue] = action.rawValue
        defaults.set(stored, forKey: "buttonActions")
        defaults.synchronize()
    }

    private static let fallbackActions: [RemoteButton: MappedAction] = [
        .back: .escape,
        .play: .mediaPlayPause,
        .mute: .volumeMute,
        .volumeUp: .volumeUp,
        .volumeDown: .volumeDown,
        .home: .returnKey
    ]
}
