import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import IOKit
import IOKit.hid

/// Wires the remote, the virtual microphone, and the input-method key.
final class AppModel {
    let preferences = Preferences()
    let remote = HIDRemote()
    let remoteMic = RemoteMicCapture()
    let talk = TalkTrigger()
    let macMic = MacMicrophone()
    let virtualMic = VirtualMicrophone()
    let bluetooth = RMVBluetooth()
    let touch = TouchSurface()
    let suppression = MediaSuppression()

    private(set) var discovered: [RMVDiscoveredRemote] = []
    private(set) var searching = false
    private(set) var pairing = false
    private(set) var reconnecting = false
    private(set) var pairMessage: String?
    private var lastDisposition: Disposition = .seen
    private var lastControlNote: String?
    private var suppressTick = 0
    private var reconnectTick = 0
    private var loginError: String?
    private var timer: Timer?
    private(set) var loginStatus = ""
    var onChange: (() -> Void)?

    private enum Disposition {
        case siri
        case ignored
        case seen
    }

    func start() {
        virtualMic.onChange = { [weak self] in self?.onChange?() }
        remoteMic.onChange = { [weak self] in self?.onChange?() }
        virtualMic.start()
        remote.onEvent = { [weak self] event in self?.handle(event) }
        remote.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.remoteMic.noteHIDConnected(connected)
            if connected {
                self.reconnecting = false
                self.reconnectTick = 0
                self.suppression.apply()
            } else {
                self.attemptReconnect()
            }
            self.onChange?()
        }
        bluetooth.devicesChanged = { [weak self] devices in
            self?.discovered = devices
            self?.onChange?()
        }
        bluetooth.searchFinished = { [weak self] status in
            self?.searching = false
            if status != kIOReturnSuccess {
                self?.pairMessage = String(
                    format: NSLocalizedString("settings.pair.failed", comment: ""),
                    Self.hex(status)
                )
            }
            self?.onChange?()
        }
        bluetooth.pairFinished = { [weak self] status in
            guard let self else { return }
            self.pairing = false
            if status == kIOReturnSuccess {
                self.pairMessage = NSLocalizedString("settings.pair.ok", comment: "")
                self.attemptReconnect()
            } else if status == kIOReturnUnsupported {
                self.pairMessage = NSLocalizedString("settings.pair.pin", comment: "")
            } else {
                self.pairMessage = String(
                    format: NSLocalizedString("settings.pair.failed", comment: ""),
                    Self.hex(status)
                )
            }
            self.onChange?()
        }
        remote.start()
        remoteMic.preferredAddress = preferences.pairedAddress
        remoteMic.startReportLog()
        remoteMic.noteHIDConnected(remote.isConnected)
        if !remote.isConnected {
            attemptReconnect()
        }
        touch.start()
        suppression.start()
        refreshControlGate()
        setLaunchAtLogin(preferences.launchAtLogin)
        requestPermissionsOnce()
        macMic.refresh()
        let ingestFlag = "/tmp/rmv-ingest-live"
        if FileManager.default.fileExists(atPath: ingestFlag) {
            try? FileManager.default.removeItem(atPath: ingestFlag)
            remoteMic.ingestTraceFile("/tmp/bt-live.pklg")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.macMic.refresh()
            self.virtualMic.refreshInstalled()
            self.touch.refreshStatus()
            self.refreshLoginStatus()
            self.suppressTick += 1
            if self.suppressTick % 8 == 0 {
                self.suppression.apply()
            }
            if !self.remote.isConnected {
                self.reconnectTick += 1
                if self.reconnectTick == 1 || self.reconnectTick % 3 == 0 {
                    self.attemptReconnect()
                }
            }
            self.onChange?()
        }
        onChange?()
    }

    func stop() {
        timer?.invalidate()
        if talk.isHoldingSiri {
            remoteMic.endHold()
            talk.end(preferences: preferences)
            RMVRingFlush()
            RMVRingUseMac()
        } else {
            remoteMic.endHold()
        }
        remote.stop()
        touch.stop()
        suppression.clear()
        macMic.stop()
        virtualMic.stop()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        preferences.launchAtLogin = enabled
        let result = LoginItem.apply(enabled: enabled)
        loginError = result.failed ? result.message : nil
        loginStatus = result.message
        onChange?()
    }

    func refreshLoginStatus() {
        guard loginError == nil else { return }
        loginStatus = LoginItem.describeCurrent()
    }

    func refreshControlGate() {
        let blocked = talk.isHoldingSiri && !preferences.allowControlsWhileSpeaking
        touch.setSuspended(blocked)
    }

    func search() {
        searching = true
        pairMessage = nil
        let status = bluetooth.startSearch()
        if status != kIOReturnSuccess {
            searching = false
            pairMessage = String(format: NSLocalizedString("settings.pair.failed", comment: ""), Self.hex(status))
        }
        onChange?()
    }

    func pair(address: String) {
        pairing = true
        preferences.pairedAddress = address
        remoteMic.preferredAddress = address
        pairMessage = NSLocalizedString("settings.pair.waiting", comment: "")
        let status = bluetooth.pairAddress(address)
        if status != kIOReturnSuccess {
            pairing = false
            pairMessage = String(format: NSLocalizedString("settings.pair.failed", comment: ""), Self.hex(status))
        }
        onChange?()
    }

    func reconnectNow() {
        reconnectTick = 0
        attemptReconnect()
        onChange?()
    }

    private func attemptReconnect() {
        guard !pairing, !searching, !remote.isConnected else {
            if remote.isConnected {
                reconnecting = false
            }
            return
        }
        reconnecting = true
        let status = bluetooth.reconnectAddress(preferences.pairedAddress)
        if status == kIOReturnNotFound {
            reconnecting = false
        }
    }

    enum RemoteStatusKind {
        case connected
        case reconnecting
        case pairedIdle
        case disconnected
    }

    func remoteStatusKind() -> RemoteStatusKind {
        if remote.isConnected { return .connected }
        if reconnecting { return .reconnecting }
        if bluetooth.isAddressPaired(preferences.pairedAddress) { return .pairedIdle }
        return .disconnected
    }

    func remoteDeviceDisplay() -> String {
        if let name = bluetooth.deviceName(forAddress: preferences.pairedAddress), !name.isEmpty {
            if name.localizedCaseInsensitiveContains("A2854") || name.localizedCaseInsensitiveContains("Siri") {
                return name
            }
            return "A2854 \(name)"
        }
        if let name = remoteMic.deviceName, !name.isEmpty {
            return "A2854 \(name)"
        }
        return "A2854"
    }

    func remoteAddressDisplay() -> String {
        if let address = bluetooth.resolvedAddress(forAddress: preferences.pairedAddress), !address.isEmpty {
            return address.uppercased()
        }
        if let address = remoteMic.deviceAddress, !address.isEmpty {
            return address.uppercased()
        }
        let stored = preferences.pairedAddress
        return stored.isEmpty ? NSLocalizedString("settings.remote.none", comment: "") : stored.uppercased()
    }

    func remoteText() -> String {
        var line: String
        if remote.isConnected {
            line = NSLocalizedString("menu.remote.connected", comment: "")
        } else if reconnecting {
            line = NSLocalizedString("menu.remote.reconnecting", comment: "")
        } else if bluetooth.isAddressPaired(preferences.pairedAddress) {
            line = NSLocalizedString("menu.remote.pairedIdle", comment: "")
        } else {
            line = NSLocalizedString("menu.remote.disconnected", comment: "")
        }
        if !Permissions.inputMonitoring {
            line += " " + NSLocalizedString("settings.input", comment: "") + " " + NSLocalizedString("settings.notGranted", comment: "")
        }
        if remote.openStatus != kIOReturnSuccess {
            line += " " + String(format: "HID 0x%08X", UInt32(bitPattern: remote.openStatus))
        }
        return line
    }

    func buttonText() -> String {
        guard let event = remote.lastEvent else {
            return NSLocalizedString("menu.button.none", comment: "")
        }
        let name = remote.provisionalName(page: event.page, usage: event.usage)
        let hex = String(format: "0x%04X/0x%04X", event.page, event.usage)
        let state: String
        if event.isSiri {
            state = event.pressed
                ? NSLocalizedString("state.pressed", comment: "")
                : NSLocalizedString("state.released", comment: "")
        } else if lastDisposition == .ignored {
            state = NSLocalizedString("state.ignored", comment: "")
        } else if let lastControlNote {
            state = lastControlNote
        } else if event.pressed {
            state = NSLocalizedString("state.seen", comment: "")
        } else {
            state = NSLocalizedString("state.released", comment: "")
        }
        return String(format: NSLocalizedString("menu.button.line", comment: ""), name, hex, state)
    }

    func micText() -> String {
        if virtualMic.ringError != 0 {
            return String(format: NSLocalizedString("settings.ring.failed", comment: ""), virtualMic.ringError)
        }
        if !virtualMic.installed {
            return NSLocalizedString("menu.mic.notInstalled", comment: "")
        }
        if talk.isHoldingSiri {
            return remoteMic.isProducingPCM
                ? NSLocalizedString("menu.mic.remoteLive", comment: "")
                : NSLocalizedString("menu.mic.remoteSilent", comment: "")
        }
        switch macMic.problem {
        case .running, .starting:
            return NSLocalizedString("menu.mic.mac", comment: "")
        case .permissionDenied:
            return NSLocalizedString("menu.mic.permission", comment: "")
        case .defaultInputIsVirtualMic:
            return NSLocalizedString("menu.mic.conflict", comment: "")
        case .formatUnavailable:
            return String(format: NSLocalizedString("menu.mic.failed", comment: ""), NSLocalizedString("menu.mic.format", comment: ""))
        case .engineFailed(let message):
            return String(format: NSLocalizedString("menu.mic.failed", comment: ""), message)
        }
    }

    func captureText() -> String {
        remoteMic.captureText()
    }

    func voiceText() -> String {
        let caveat = preferences.engine == .wechat ? " " + NSLocalizedString("menu.voice.wechat", comment: "") : ""
        switch talk.phase {
        case .idle:
            return NSLocalizedString("menu.voice.idle", comment: "") + caveat
        case .holding:
            let line = String(
                format: NSLocalizedString("menu.voice.holding", comment: ""),
                engineName(),
                keyName()
            )
            return line + caveat
        case .missingEngine:
            return String(format: NSLocalizedString("menu.voice.missing", comment: ""), engineName())
        case .needsAccessibility:
            return NSLocalizedString("menu.voice.needsAccess", comment: "")
        }
    }

    func engineName() -> String {
        switch preferences.engine {
        case .doubao: return NSLocalizedString("engine.doubao", comment: "")
        case .wechat: return NSLocalizedString("engine.wechat", comment: "")
        }
    }

    func keyName() -> String {
        switch preferences.talkKey {
        case .rightCommand: return NSLocalizedString("key.rightCommand", comment: "")
        case .leftOption: return NSLocalizedString("key.leftOption", comment: "")
        case .fn: return NSLocalizedString("key.fn", comment: "")
        }
    }

    private func handle(_ event: HIDRemote.Event) {
        if event.isSiri {
            lastDisposition = .siri
            lastControlNote = nil
            if event.pressed {
                talk.begin(preferences: preferences)
                // Doubao's key stays as it was. The hold leaves the Mac mic
                // and tails the HCI trace into RmoteVibe Mic.
                remoteMic.beginHold()
            } else {
                remoteMic.endHold()
                talk.end(preferences: preferences)
                RMVRingFlush()
                RMVRingUseMac()
            }
            refreshControlGate()
        } else if talk.isHoldingSiri && !preferences.allowControlsWhileSpeaking {
            lastDisposition = .ignored
            lastControlNote = nil
            if event.page == 0x0C && event.usage == 0x80 {
                touch.setCenterDown(false)
            }
        } else if event.page == 0x0C && event.usage == 0x80 {
            lastDisposition = .seen
            touch.setCenterDown(event.pressed)
            lastControlNote = event.pressed
                ? NSLocalizedString("state.mouseDown", comment: "")
                : NSLocalizedString("state.mouseUp", comment: "")
        } else if event.pressed, let button = RemoteButton.match(page: event.page, usage: event.usage) {
            lastDisposition = .seen
            let action = preferences.action(for: button)
            if action.perform() {
                lastControlNote = NSLocalizedString(action.titleKey, comment: "")
            } else {
                lastControlNote = NSLocalizedString("menu.voice.needsAccess", comment: "")
            }
        } else {
            lastDisposition = .seen
            lastControlNote = nil
        }
        onChange?()
    }

    private func requestPermissionsOnce() {
        if !Permissions.inputMonitoring {
            Permissions.requestInputMonitoring()
        }
        if !Permissions.accessibility {
            Permissions.requestAccessibility()
        }
    }

    private static func hex(_ status: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestMicrophone(done: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async(execute: done)
        }
    }
}
