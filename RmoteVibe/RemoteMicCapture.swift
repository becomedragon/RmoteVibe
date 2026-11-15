import CoreAudio
import Foundation
import os

/// While Siri is held, tail bluetoothd's HCI file, decode ATT notifications
/// on attribute 0x0036 (Opus TOC 0xB8) and write that PCM into RmoteVibe Mic.
/// On release the caller points the virtual mic back at the Mac microphone.
/// HID stays a separate non-seizing session, so touch and buttons still arrive.
final class RemoteMicCapture {
    static let rejectedAndroidTVVoiceService = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"

    private let session = RMVVoiceCapture()
    private let voiceFeed = HCIVoiceFeed()
    private(set) var isHolding = false
    private(set) var didRun = false
    /// True only after decoded remote PCM has been written.
    private(set) var isProducingPCM = false
    private(set) var hidProductVisible = false
    private(set) var coreAudioInputCount = 0
    private(set) var coreAudioListedRemote = false

    var preferredAddress: String {
        get { session.preferredAddress }
        set { session.preferredAddress = newValue }
    }

    var deviceName: String? { session.deviceName }
    var deviceAddress: String? { session.deviceAddress }

    var onChange: (() -> Void)? {
        didSet {
            session.statusChanged = { [weak self] in
                self?.onChange?()
            }
        }
    }

    func noteHIDConnected(_ connected: Bool) {
        hidProductVisible = connected
    }

    /// Record report id and length from launch until quit. Not a decoder.
    func startReportLog() {
        session.startReportLog()
    }

    func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        didRun = true
        isProducingPCM = false
        let names = SystemInput.inputDeviceNames()
        coreAudioInputCount = names.count
        coreAudioListedRemote = names.contains(where: Self.looksLikeThisRemote)
        // Mac samples stop. Silence holds the gap until a decoded packet arrives.
        RMVRingUseSilence()
        RMVRingFlush()
        session.beginHold()
        voiceFeed.start { [weak self] stereo in
            DispatchQueue.main.async {
                self?.acceptVerifiedPCM(stereo)
            }
        }
        onChange?()
    }

    func endHold() {
        guard isHolding else { return }
        isHolding = false
        isProducingPCM = false
        voiceFeed.stop()
        session.endHold()
        onChange?()
    }

    /// Decode an HCI file already on disk and write it through the same
    /// path a live hold uses. Does not seek to the end, so frames that were
    /// in the file before the button press are included.
    func ingestTraceFile(_ path: String) {
        guard !isHolding else { return }
        isHolding = true
        defer { isHolding = false }
        guard RMVOpusDecoderOpen() == 0, let trace = RMVHCITraceOpen(path) else { return }
        defer {
            RMVHCITraceClose(trace)
            RMVOpusDecoderClose()
        }
        var packet = [UInt8](repeating: 0, count: 256)
        var pcm = [Float](repeating: 0, count: 5760)
        var mono = [Float]()
        var packets = 0
        while true {
            let length = packet.withUnsafeMutableBufferPointer { buffer in
                RMVHCITraceNextOpus(trace, buffer.baseAddress, Int32(buffer.count))
            }
            if length <= 0 { break }
            let samples = pcm.withUnsafeMutableBufferPointer { destination in
                packet.withUnsafeBufferPointer { source in
                    RMVOpusDecodePacket(source.baseAddress, length, destination.baseAddress, Int32(destination.count))
                }
            }
            guard samples > 0 else { continue }
            packets += 1
            mono.append(contentsOf: pcm.prefix(Int(samples)))
        }
        let window = min(mono.count, 48000)
        guard packets > 0, window > 0 else { return }
        var bestStart = 0
        var bestEnergy = 0.0
        if mono.count > window {
            var start = 0
            while start + window <= mono.count {
                var energy = 0.0
                for index in start..<(start + window) {
                    let sample = Double(mono[index])
                    energy += sample * sample
                }
                if energy > bestEnergy {
                    bestEnergy = energy
                    bestStart = start
                }
                start += 4800
            }
        }
        var stereo = [Float]()
        stereo.reserveCapacity(window * 2)
        var peak = Float(0)
        for index in bestStart..<(bestStart + window) {
            let sample = mono[index]
            let magnitude = sample < 0 ? -sample : sample
            if magnitude > peak { peak = magnitude }
            stereo.append(sample)
            stereo.append(sample)
        }
        let writer = RMVRingOpenWriter()
        acceptVerifiedPCM(stereo)
        let note = "ingest packets \(packets) samples \(mono.count) ringFrames \(window) peak \(peak) writer \(writer) feed \(RMVRingFeed())\n"
        if let data = note.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/rmv-ingest.log") {
                if let handle = FileHandle(forWritingAtPath: "/tmp/rmv-ingest.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: "/tmp/rmv-ingest.log"))
            }
        }
    }

    /// Writes decoded 48 kHz stereo from the HCI voice stream. Ignored once
    /// the Siri button has been released.
    func acceptVerifiedPCM(_ interleavedStereo48k: [Float]) {
        guard isHolding, !interleavedStereo48k.isEmpty else { return }
        let frames = UInt32(interleavedStereo48k.count / Int(RMVRingChannels))
        guard frames > 0 else { return }
        RMVRingUseRemote()
        isProducingPCM = true
        interleavedStereo48k.withUnsafeBufferPointer { pointer in
            RMVRingWriteInterleaved(pointer.baseAddress, frames)
        }
        onChange?()
    }

    func captureText() -> String {
        guard didRun else {
            return NSLocalizedString("menu.capture.idle", comment: "")
        }
        let when = isHolding
            ? NSLocalizedString("capture.when.now", comment: "")
            : NSLocalizedString("capture.when.last", comment: "")
        let l2cap = session.l2capSummary
        let ids = session.hidReportIDs
        var tail = tailPhrase
        if session.hidOpenStatus != 0 {
            let failed = String(
                format: NSLocalizedString("capture.hid.failed", comment: ""),
                Self.hex(session.hidOpenStatus)
            )
            tail = failed + " " + tail
        } else if session.hidRegisterStatus != 0 {
            let failed = String(
                format: NSLocalizedString("capture.hid.register", comment: ""),
                Self.hex(session.hidRegisterStatus)
            )
            tail = failed + " " + tail
        }
        return String(
            format: NSLocalizedString("menu.capture.line", comment: ""),
            when,
            linkPhrase,
            sdpPhrase,
            session.l2capCount,
            l2cap.isEmpty ? NSLocalizedString("capture.none", comment: "") : l2cap,
            session.hidReportCount,
            session.hidMaxBytes,
            ids.isEmpty ? NSLocalizedString("capture.none", comment: "") : ids,
            coreAudioInputCount,
            tail
        )
    }

    private var linkPhrase: String {
        guard session.deviceFound else {
            var phrase = NSLocalizedString("capture.bt.missing", comment: "")
            if hidProductVisible {
                phrase += " " + NSLocalizedString("capture.hid.present", comment: "")
            }
            return phrase
        }
        let state = session.deviceConnected
            ? NSLocalizedString("capture.bt.connected", comment: "")
            : NSLocalizedString("capture.bt.disconnected", comment: "")
        let name = session.deviceName ?? session.deviceAddress ?? NSLocalizedString("menu.remote.disconnected", comment: "")
        let phrase: String
        if session.matchedBySerial {
            phrase = String(format: NSLocalizedString("capture.bt.serial", comment: ""), name, state)
        } else {
            phrase = String(format: NSLocalizedString("capture.bt.found", comment: ""), name, state)
        }
        guard hidProductVisible else {
            return phrase + " " + NSLocalizedString("capture.hid.absent", comment: "")
        }
        return phrase
    }

    private var sdpPhrase: String {
        if session.sdpSkipped {
            return NSLocalizedString("capture.sdp.skipped", comment: "")
        }
        if !session.sdpFinished {
            return NSLocalizedString("capture.sdp.waiting", comment: "")
        }
        let summary = session.sdpServiceSummary
        return String(
            format: NSLocalizedString("capture.sdp.done", comment: ""),
            session.sdpServiceCount,
            Self.hex(session.sdpStatus),
            summary.isEmpty ? NSLocalizedString("capture.none", comment: "") : summary
        )
    }

    private var tailPhrase: String {
        if session.sawAndroidTVVoiceService {
            return NSLocalizedString("capture.tail.atvv", comment: "")
        }
        if session.sawClassicAudioUUID {
            return NSLocalizedString("capture.tail.classic", comment: "")
        }
        if coreAudioListedRemote {
            return NSLocalizedString("capture.tail.coreaudio", comment: "")
        }
        return NSLocalizedString("capture.tail.none", comment: "")
    }

    private static func looksLikeThisRemote(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("rmotevibe") {
            return false
        }
        return lower.contains("siri")
            || lower.contains("a2854")
            || lower.contains("apple tv")
            || lower.contains("remote")
    }

    private static func hex(_ status: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }
}

/// Decodes Opus packets that arrive after the Siri press.
/// Stop drops the reader so a later hold does not keep the old decoder.
private final class HCIVoiceFeed {
    private let queue = DispatchQueue(label: "dev.rmotevibe.hci-voice")
    private let log = Logger(subsystem: "dev.rmotevibe.RmoteVibe", category: "voice")
    private var timer: DispatchSourceTimer?
    private var trace: OpaquePointer?
    private var path: String?

    func start(deliver: @escaping ([Float]) -> Void) {
        queue.async { [weak self] in
            self?.startOnQueue(deliver: deliver)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(deliver: @escaping ([Float]) -> Void) {
        stopOnQueue()
        guard let rawPath = RMVHCITracePreferredPath() else { return }
        let opened = String(cString: rawPath)
        guard let openedTrace = RMVHCITraceOpen(opened) else { return }
        guard RMVOpusDecoderOpen() == 0 else {
            RMVHCITraceClose(openedTrace)
            return
        }
        path = opened
        trace = openedTrace
        // Earlier holds stay in this file. Reading them from the first byte
        // fills the one-second ring faster than realtime, and the client
        // keeps only the latest 50 ms, so the start of this press is lost.
        RMVHCITraceSeekEnd(openedTrace)
        log.log("Voice feed started at the end of the HCI trace")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            self?.pull(deliver: deliver)
        }
        self.timer = timer
        timer.resume()
    }

    private func stopOnQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let trace {
            RMVHCITraceClose(trace)
        }
        trace = nil
        path = nil
        RMVOpusDecoderClose()
    }

    private func pull(deliver: @escaping ([Float]) -> Void) {
        guard let trace, let path else { return }
        RMVHCITraceFollow(trace, path)
        var packet = [UInt8](repeating: 0, count: 256)
        var pcm = [Float](repeating: 0, count: 5760)
        for _ in 0..<12 {
            let length = packet.withUnsafeMutableBufferPointer { buffer in
                RMVHCITraceNextOpus(trace, buffer.baseAddress, Int32(buffer.count))
            }
            if length <= 0 {
                return
            }
            let samples = pcm.withUnsafeMutableBufferPointer { destination in
                packet.withUnsafeBufferPointer { source in
                    RMVOpusDecodePacket(source.baseAddress, length, destination.baseAddress, Int32(destination.count))
                }
            }
            guard samples > 0 else { continue }
            var stereo = [Float]()
            stereo.reserveCapacity(Int(samples) * 2)
            for index in 0..<Int(samples) {
                let sample = pcm[index]
                stereo.append(sample)
                stereo.append(sample)
            }
            deliver(stereo)
        }
    }
}
