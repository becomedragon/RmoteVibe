import AppKit
import CoreGraphics
import Darwin
import Foundation

/// UNVERIFIED REPORT LAYOUT.
///
/// Public IOHID does not deliver A2854 finger positions (digitizer 0x0D/0x01
/// stays silent). This file loads the private MultitouchSupport framework and
/// reads the first contact with the byte offsets published for a Mac trackpad.
/// Those offsets have not been checked on this remote or on macOS 27.2.
/// A second finger is ignored because the record stride is not known.
/// Positions outside 0...1 are dropped so a wrong layout does not fling the cursor.
/// Positive Y is treated as up. That direction is not verified.
final class TouchSurface {
    private(set) var statusText = ""

    private var suspended = false
    private var library: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var startedDevices: [UnsafeMutableRawPointer] = []
    private var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var unregister: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void)?

    private var fingerDown = false
    private var centerDown = false
    private var buttonPosted = false
    private var phase: Phase = .idle
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var downAt = 0.0
    private var scrollRemainder: CGFloat = 0
    private var sentPointer = false
    private var sawOutOfRange = false
    private var lastCount = 0
    private var lastSampleAt = 0.0
    private var settleLeft = 0

    private let tapSlop: CGFloat = 0.03
    private let edgeBand: CGFloat = 0.12
    private let tapLimit = 0.35
    /// Pad span in pointer points. 1800 treated the click-ring as a huge trackpad.
    private let pointsAcross: CGFloat = 680
    private let scrollScale: CGFloat = 900
    /// Ignore normalized jitter so the cursor does not shimmer.
    private let jitter: CGFloat = 0.003
    /// Finger-up then a new landing must not teleport from the old last sample.
    private let wrapJump: CGFloat = 0.20
    private let contactGap = 0.08
    private let accelGain: CGFloat = 14
    private let accelExtra: CGFloat = 0.55

    func start() {
        if library != nil {
            publish()
            return
        }
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            statusText = NSLocalizedString("touch.missing", comment: "")
            return
        }
        library = handle
        guard let create = load(handle, "MTDeviceCreateList", CreateList.self),
              let register = load(handle, "MTRegisterContactFrameCallback", RegisterCallback.self),
              let start = load(handle, "MTDeviceStart", StartDevice.self),
              let stop = load(handle, "MTDeviceStop", StopDevice.self),
              let builtIn = load(handle, "MTDeviceIsBuiltIn", IsBuiltIn.self) else {
            statusText = NSLocalizedString("touch.symbols", comment: "")
            return
        }
        stopDevice = stop
        unregister = load(handle, "MTUnregisterContactFrameCallback", RegisterCallback.self)
        TouchHub.shared.surface = self
        guard let rawList = create() else {
            statusText = NSLocalizedString("touch.none", comment: "")
            return
        }
        // Ownership of this list is unverified. Holding it with ARC is enough
        // for the process lifetime; a Create-rule leak of one array is accepted.
        let list = Unmanaged<CFArray>.fromOpaque(rawList).takeUnretainedValue()
        deviceList = list
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            if builtIn(device) {
                continue
            }
            register(device, rmvContactFrame)
            start(device, 0)
            startedDevices.append(device)
        }
        publish()
    }

    func stop() {
        releaseButton()
        phase = .idle
        fingerDown = false
        for device in startedDevices {
            stopDevice?(device)
            unregister?(device, rmvContactFrame)
        }
        startedDevices.removeAll()
        TouchHub.shared.surface = nil
    }

    /// While Siri is held this is true unless the allow-together setting is on.
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended {
            endContact(clickIfTap: false)
            releaseButton()
            centerDown = false
        }
        publish()
    }

    /// Click-ring center is the mouse button. It is not a settings action.
    /// Drag is this button held plus finger travel past the tap slop.
    /// An edge scroll already in progress does not become a drag.
    func setCenterDown(_ down: Bool) {
        if suspended {
            releaseButton()
            centerDown = false
            publish()
            return
        }
        guard down != centerDown else { return }
        centerDown = down
        if down {
            if case .scrolling = phase {
                publish()
                return
            }
            postButton(down: true)
            if fingerDown {
                phase = .dragging
            }
        } else {
            releaseButton()
            if case .dragging = phase {
                phase = fingerDown ? .moving : .idle
            }
        }
        publish()
    }

    fileprivate func ingest(touches: UnsafeMutableRawPointer?, count: Int32) {
        let sample = Self.readFirstContact(touches: touches, count: count)
        DispatchQueue.main.async { [weak self] in
            self?.apply(sample, count: Int(count))
        }
    }

    private func apply(_ sample: Contact?, count: Int) {
        lastCount = max(0, count)
        if suspended {
            endContact(clickIfTap: false)
            publish()
            return
        }
        guard let sample else {
            if fingerDown {
                endContact(clickIfTap: true)
            }
            publish()
            return
        }
        guard sample.x.isFinite, sample.y.isFinite, sample.x >= 0, sample.x <= 1, sample.y >= 0, sample.y <= 1 else {
            sawOutOfRange = true
            publish()
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        if fingerDown, now - lastSampleAt > contactGap {
            beginContact(sample)
            publish()
            return
        }
        lastSampleAt = now
        if !fingerDown {
            beginContact(sample)
            publish()
            return
        }
        if settleLeft > 0 {
            settleLeft -= 1
            let point = CGPoint(x: sample.x, y: sample.y)
            origin = point
            last = point
            if case .pending(_, let at, _) = phase {
                phase = .pending(origin: point, at: at, edge: edge(of: point))
            }
            publish()
            return
        }
        let dx = sample.x - last.x
        let dy = sample.y - last.y
        if abs(dx) > wrapJump || abs(dy) > wrapJump {
            last = CGPoint(x: sample.x, y: sample.y)
            publish()
            return
        }
        let travel = hypot(sample.x - origin.x, sample.y - origin.y)
        switch phase {
        case .pending(_, _, let edge):
            if centerDown && travel > tapSlop {
                phase = .dragging
                movePointer(dx: sample.x - origin.x, dy: sample.y - origin.y, dragging: true)
                sentPointer = true
            } else if edge != nil && travel > tapSlop && !centerDown {
                phase = .scrolling(edge ?? .left)
                scroll(edge: edge ?? .left, dx: sample.x - origin.x, dy: sample.y - origin.y)
            } else if travel > tapSlop && !centerDown {
                phase = .moving
                movePointer(dx: sample.x - origin.x, dy: sample.y - origin.y, dragging: false)
                sentPointer = true
            }
        case .moving:
            movePointer(dx: dx, dy: dy, dragging: false)
        case .dragging:
            if travel > tapSlop {
                if sentPointer {
                    movePointer(dx: dx, dy: dy, dragging: true)
                } else {
                    movePointer(dx: sample.x - origin.x, dy: sample.y - origin.y, dragging: true)
                    sentPointer = true
                }
            }
        case .scrolling(let edge):
            scroll(edge: edge, dx: dx, dy: dy)
        case .idle:
            break
        }
        last = CGPoint(x: sample.x, y: sample.y)
        publish()
    }

    private func beginContact(_ sample: Contact) {
        fingerDown = true
        origin = CGPoint(x: sample.x, y: sample.y)
        last = origin
        downAt = Date.timeIntervalSinceReferenceDate
        lastSampleAt = downAt
        scrollRemainder = 0
        sentPointer = false
        settleLeft = 2
        if centerDown && buttonPosted {
            phase = .dragging
        } else {
            phase = .pending(origin: origin, at: downAt, edge: edge(of: origin))
        }
    }

    private func endContact(clickIfTap: Bool) {
        if clickIfTap, case .pending(let origin, let at, _) = phase {
            let travel = hypot(last.x - origin.x, last.y - origin.y)
            let duration = Date.timeIntervalSinceReferenceDate - at
            if !centerDown && travel <= tapSlop && duration <= tapLimit {
                postClick()
            }
        }
        fingerDown = false
        last = .zero
        settleLeft = 0
        lastSampleAt = 0
        scrollRemainder = 0
        sentPointer = false
        if centerDown && buttonPosted {
            phase = .dragging
        } else {
            phase = .idle
        }
    }

    private func edge(of point: CGPoint) -> Edge? {
        let choices: [(CGFloat, Edge)] = [
            (point.x, .left),
            (1 - point.x, .right),
            (point.y, .bottom),
            (1 - point.y, .top)
        ]
        guard let best = choices.min(by: { $0.0 < $1.0 }), best.0 <= edgeBand else {
            return nil
        }
        return best.1
    }

    private func movePointer(dx: CGFloat, dy: CGFloat, dragging: Bool) {
        guard Permissions.accessibility, let current = CGEvent(source: nil)?.location else {
            return
        }
        let mag = hypot(dx, dy)
        guard mag >= jitter else { return }
        let accel = 1 + min(mag * accelGain, accelExtra)
        let scale = pointsAcross * accel
        let point = CGPoint(x: current.x + dx * scale, y: current.y - dy * scale)
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        postMouse(type, at: point, button: .left)
    }

    private func scroll(edge: Edge, dx: CGFloat, dy: CGFloat) {
        let raw: CGFloat
        let vertical: Bool
        switch edge {
        case .left, .right:
            raw = dy * scrollScale
            vertical = true
        case .top, .bottom:
            raw = dx * scrollScale
            vertical = false
        }
        scrollRemainder += raw
        let whole = Int32(scrollRemainder)
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        guard Permissions.accessibility,
              let event = CGEvent(
                scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical ? whole : 0,
                wheel2: vertical ? 0 : whole,
                wheel3: 0
              ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postClick() {
        guard let point = CGEvent(source: nil)?.location else { return }
        postMouse(.leftMouseDown, at: point, button: .left)
        postMouse(.leftMouseUp, at: point, button: .left)
    }

    private func postButton(down: Bool) {
        guard !down || !buttonPosted else { return }
        guard down || buttonPosted else { return }
        guard let point = CGEvent(source: nil)?.location else { return }
        postMouse(down ? .leftMouseDown : .leftMouseUp, at: point, button: .left)
        buttonPosted = down
    }

    private func releaseButton() {
        postButton(down: false)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard Permissions.accessibility,
              let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
              ) else { return }
        event.post(tap: .cghidEventTap)
    }

    func refreshStatus() {
        publish()
    }

    private func publish() {
        if suspended {
            statusText = NSLocalizedString("touch.suspended", comment: "")
            return
        }
        if !Permissions.accessibility {
            statusText = NSLocalizedString("touch.needsAccess", comment: "")
            return
        }
        if startedDevices.isEmpty {
            statusText = NSLocalizedString("touch.none", comment: "")
            return
        }
        let phaseName: String
        switch phase {
        case .idle: phaseName = NSLocalizedString("touch.phase.idle", comment: "")
        case .pending: phaseName = NSLocalizedString("touch.phase.pending", comment: "")
        case .moving: phaseName = NSLocalizedString("touch.phase.move", comment: "")
        case .scrolling: phaseName = NSLocalizedString("touch.phase.scroll", comment: "")
        case .dragging: phaseName = NSLocalizedString("touch.phase.drag", comment: "")
        }
        var line = String(
            format: NSLocalizedString("touch.running", comment: ""),
            Int32(lastCount),
            phaseName
        )
        if sawOutOfRange {
            line += " " + NSLocalizedString("touch.outOfRange", comment: "")
        }
        if lastCount > 1 {
            line += " " + NSLocalizedString("touch.extraFingers", comment: "")
        }
        statusText = line
    }

    private struct Contact {
        var x: CGFloat
        var y: CGFloat
    }

    private enum Edge {
        case left, right, top, bottom
    }

    private enum Phase {
        case idle
        case pending(origin: CGPoint, at: TimeInterval, edge: Edge?)
        case moving
        case scrolling(Edge)
        case dragging
    }

    /// First contact only. Offsets are the public trackpad prefix and are UNVERIFIED here.
    private static func readFirstContact(touches: UnsafeMutableRawPointer?, count: Int32) -> Contact? {
        guard count > 0, let touches else { return nil }
        let base = UnsafeRawPointer(touches)
        let x = CGFloat(base.load(fromByteOffset: 32, as: Float.self))
        let y = CGFloat(base.load(fromByteOffset: 36, as: Float.self))
        return Contact(x: x, y: y)
    }

    private func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

private final class TouchHub {
    static let shared = TouchHub()
    weak var surface: TouchSurface?
}

private typealias ContactCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Void

private typealias CreateList = @convention(c) () -> UnsafeMutableRawPointer?
private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer) -> Void
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> CBool

private func rmvContactFrame(
    _ device: UnsafeMutableRawPointer?,
    _ touches: UnsafeMutableRawPointer?,
    _ count: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    _ = timestamp
    _ = frame
    TouchHub.shared.surface?.ingest(touches: touches, count: count)
}
