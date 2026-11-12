import AVFoundation
import CoreAudio
import Foundation

/// Plays the Mac's current default input into the shared ring while the feed
/// flag is the Mac. Never opens RmoteVibe Mic, so it cannot loop.
final class MacMicrophone {
    enum Problem: Equatable {
        case starting
        case permissionDenied
        case defaultInputIsVirtualMic
        case formatUnavailable
        case running
        case engineFailed(String)
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(RMVRingSampleRate),
        channels: 1,
        interleaved: false
    )
    private var started = false
    private(set) var problem: Problem = .starting

    func refresh() {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        switch permission {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
            return
        case .denied, .restricted:
            stop()
            problem = .permissionDenied
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        let virtualUID = String(cString: RMVDeviceUID)
        if SystemInput.defaultUID() == virtualUID {
            stop()
            problem = .defaultInputIsVirtualMic
            return
        }
        if started {
            problem = .running
            return
        }
        do {
            try startEngine()
            problem = .running
        } catch MicError.format {
            problem = .formatUnavailable
        } catch {
            problem = .engineFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        started = false
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0, let targetFormat else {
            throw MicError.format
        }
        guard let converter = AVAudioConverter(from: hardware, to: targetFormat) else {
            throw MicError.format
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 512, format: hardware) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        try engine.start()
        started = true
    }

    private func write(_ input: AVAudioPCMBuffer) {
        guard RMVRingFeed() == RMVFeedMac, let converter, let targetFormat else {
            return
        }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 32)) else {
            return
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let channels = output.floatChannelData else {
            return
        }
        let frames = Int(output.frameLength)
        var interleaved = [Float](repeating: 0, count: frames * 2)
        let mono = channels[0]
        for index in 0..<frames {
            let sample = mono[index]
            interleaved[index * 2] = sample
            interleaved[index * 2 + 1] = sample
        }
        interleaved.withUnsafeBufferPointer { pointer in
            RMVRingWriteInterleaved(pointer.baseAddress, UInt32(frames))
        }
    }

    private enum MicError: Error {
        case format
    }
}

enum SystemInput {
    static func defaultUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr, device != 0 else {
            return nil
        }
        return uid(of: device)
    }

    static func deviceExists(uid target: String) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return false
        }
        return devices.contains { uid(of: $0) == target }
    }

    /// Names of devices that expose an input stream. RmoteVibe Mic is included
    /// when it is installed. The remote is not expected to be in this list.
    static func inputDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        var names: [String] = []
        for device in devices where hasInputStream(device) {
            if let name = stringProperty(kAudioObjectPropertyName, device: device) {
                names.append(name)
            }
        }
        return names
    }

    private static func hasInputStream(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, device: device)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Device UID is a +1 CFString. The slot is pointer-sized; takeRetainedValue
        // balances the retain Core Audio documents for CF property values.
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else {
            return nil
        }
        return raw.takeRetainedValue() as String
    }
}
