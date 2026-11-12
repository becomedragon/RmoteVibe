import Foundation
import IOKit
import IOKit.hid

/// Watches a paired A2854 (vendor 0x004C, product 0x0315) and reports
/// press and release. Usages other than Siri come from one public dump and
/// are labels only. The hex value is what was read.
final class HIDRemote {
    struct Event {
        var page: UInt32
        var usage: UInt32
        var pressed: Bool
        var time: TimeInterval

        var isSiri: Bool { page == 0x0C && usage == 0x04 }
    }

    var onEvent: ((Event) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var manager: IOHIDManager?
    private var devices = Set<UInt64>()
    private var reportBuffers: [ReportBuffer] = []
    private var lastByUsage: [UInt64: (pressed: Bool, time: TimeInterval)] = [:]
    private(set) var lastEvent: Event?
    private(set) var isConnected = false
    private(set) var openStatus: IOReturn = kIOReturnSuccess

    func start() {
        if manager != nil {
            return
        }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let created = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: 0x004C,
            kIOHIDProductIDKey as String: 0x0315
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(created, matching)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(created, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().add(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(created, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().remove(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(created, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openStatus = IOHIDManagerOpen(created, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = created
        // Modern SDK: CopyDevices is CFSet?. If Xcode says Unmanaged<CFSet>,
        // call takeRetainedValue() on that result before the Set cast.
        if let existing = IOHIDManagerCopyDevices(created) {
            for device in existing as! Set<IOHIDDevice> {
                add(device)
            }
        }
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        devices.removeAll()
        setConnected(false)
    }

    func provisionalName(page: UInt32, usage: UInt32) -> String {
        switch (page, usage) {
        case (0x0C, 0x04): return NSLocalizedString("control.siri", comment: "")
        case (0x0C, 0x42): return NSLocalizedString("control.up", comment: "")
        case (0x0C, 0x43): return NSLocalizedString("control.down", comment: "")
        case (0x0C, 0x44): return NSLocalizedString("control.left", comment: "")
        case (0x0C, 0x45): return NSLocalizedString("control.right", comment: "")
        case (0x0C, 0x80): return NSLocalizedString("control.center", comment: "")
        case (0x01, 0x86): return NSLocalizedString("control.back", comment: "")
        case (0x0C, 0x60): return NSLocalizedString("control.home", comment: "")
        case (0x0C, 0xCD): return NSLocalizedString("control.play", comment: "")
        case (0x0C, 0xE2): return NSLocalizedString("control.mute", comment: "")
        case (0x0C, 0xE9): return NSLocalizedString("control.volumeUp", comment: "")
        case (0x0C, 0xEA): return NSLocalizedString("control.volumeDown", comment: "")
        default: return NSLocalizedString("control.unknown", comment: "")
        }
    }

    private func add(_ device: IOHIDDevice) {
        let id = registryID(device)
        devices.insert(id)
        if reportBuffers.contains(where: { $0.registry == id }) == false {
            let slot = ReportBuffer(registry: id)
            reportBuffers.append(slot)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, slot.bytes, slot.capacity, { context, result, _, _, reportID, report, reportLength in
                guard let context, result == kIOReturnSuccess else { return }
                Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().handleReport(
                    reportID: reportID,
                    report: report,
                    length: reportLength
                )
            }, context)
        }
        setConnected(true)
    }

    private func remove(_ device: IOHIDDevice) {
        devices.remove(registryID(device))
        setConnected(!devices.isEmpty)
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var entry: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        _ = IORegistryEntryGetRegistryEntryID(service, &entry)
        return entry
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        let now = Date.timeIntervalSinceReferenceDate
        let key = (UInt64(page) << 32) | UInt64(usage)
        if let last = lastByUsage[key], last.pressed == pressed, now - last.time < 0.02 {
            return
        }
        lastByUsage[key] = (pressed, now)
        let event = Event(page: page, usage: usage, pressed: pressed, time: now)
        lastEvent = event
        onEvent?(event)
    }

    /// Report 0xFB is the button mask the raw callback actually delivers.
    /// Siri is bit 5 (0x20). The element-value path looks for usage 0x04 and
    /// stayed quiet while these reports were logged.
    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>?, length: CFIndex) {
        guard reportID == 0xFB, let report, length > 0 else { return }
        let mask: UInt8
        if report[0] == 0xFB {
            guard length > 1 else { return }
            mask = report[1]
        } else {
            mask = report[0]
        }
        let pressed = (mask & 0x20) != 0
        let key = (UInt64(0x0C) << 32) | UInt64(0x04)
        if let last = lastByUsage[key], last.pressed == pressed {
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        if !pressed, lastByUsage[key] == nil {
            lastByUsage[key] = (false, now)
            return
        }
        lastByUsage[key] = (pressed, now)
        let event = Event(page: 0x0C, usage: 0x04, pressed: pressed, time: now)
        lastEvent = event
        onEvent?(event)
    }
}

private final class ReportBuffer {
    let registry: UInt64
    let bytes: UnsafeMutablePointer<UInt8>
    let capacity: Int

    init(registry: UInt64) {
        self.registry = registry
        capacity = 64
        bytes = .allocate(capacity: capacity)
        bytes.initialize(repeating: 0, count: capacity)
    }
}
