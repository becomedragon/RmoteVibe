import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Switches to the selected input method and posts its hold key.
/// Right Command, Left Option, and Fn (Globe, key code 0x3F) can be posted.
/// This posts a key-down while Siri is held and a key-up on release.
final class TalkTrigger {
    enum Phase: Equatable {
        case idle
        case holding
        case missingEngine
        case needsAccessibility
    }

    private(set) var phase: Phase = .idle
    private(set) var isHoldingSiri = false

    /// 100 ms, not measured. Exists so the input source can settle.
    private let switchLead: TimeInterval = 0.1
    /// 0.8 s, not measured. Only used when restore is turned on.
    private let restoreDelay: TimeInterval = 0.8

    private var generation = 0
    private var keyIsDown = false
    private var postedKey: Preferences.TalkKey = .fn
    private var previousSourceID: String?
    private let log = Logger(subsystem: "dev.rmotevibe.RmoteVibe", category: "talk")

    func begin(preferences: Preferences) {
        guard !isHoldingSiri else { return }
        generation += 1
        let token = generation
        isHoldingSiri = true
        previousSourceID = RMVCurrentInputSourceID() as String?
        let engine = preferences.engine
        let key = preferences.talkKey
        postedKey = key

        guard let sourceID = Self.sourceID(for: engine), RMVInputSourceExists(sourceID) else {
            phase = .missingEngine
            log.error("Input source is not installed for the selected engine")
            return
        }
        let selected = RMVSelectInputSourceID(sourceID)
        if !selected {
            phase = .missingEngine
            return
        }
        guard AXIsProcessTrusted() else {
            phase = .needsAccessibility
            log.error("Accessibility is not granted. The talk key was not posted.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + switchLead) { [weak self] in
            guard let self, self.generation == token, self.isHoldingSiri else { return }
            self.post(key: key, down: true)
            self.keyIsDown = true
            self.phase = .holding
            self.log.log("Posted talk key down")
        }
    }

    func end(preferences: Preferences) {
        isHoldingSiri = false
        generation += 1
        let token = generation
        if keyIsDown {
            post(key: postedKey, down: false)
            keyIsDown = false
            log.log("Posted talk key up")
        }
        phase = .idle
        guard preferences.restorePreviousInputSource, let previous = previousSourceID else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            guard let self, self.generation == token, !self.isHoldingSiri else { return }
            _ = RMVSelectInputSourceID(previous)
        }
    }

    private func post(key: Preferences.TalkKey, down: Bool) {
        let code: CGKeyCode
        let flag: CGEventFlags
        switch key {
        case .rightCommand:
            code = 0x36
            flag = .maskCommand
        case .leftOption:
            code = 0x3A
            flag = .maskAlternate
        case .fn:
            code = 0x3F
            flag = .maskSecondaryFn
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            return
        }
        event.flags = down ? flag : []
        event.post(tap: .cghidEventTap)
    }

    private static func sourceID(for engine: Preferences.Engine) -> String? {
        switch engine {
        case .doubao:
            let id = "com.bytedance.inputmethod.doubaoime.pinyin"
            return id
        case .wechat:
            let candidates = [
                "com.tencent.inputmethod.wetype",
                "com.tencent.inputmethod.wetype.pinyin"
            ]
            return candidates.first { RMVInputSourceExists($0) } ?? candidates[0]
        }
    }
}
