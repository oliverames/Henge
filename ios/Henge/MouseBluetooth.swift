import CoreBluetooth
import Foundation
import UIKit

/// A mouse read through its maker's own Bluetooth channel, for an iPhone with AssistiveTouch off.
///
/// An iPhone passes an app no mouse input without AssistiveTouch: GameController announces the mouse but its
/// state never changes, and iOS hides the standard HID-over-GATT service (0x1812) from apps. A vendor's own GATT
/// service stays reachable. Logitech's HID++ 2.0 can divert a mouse's motion, buttons and wheels to software, so
/// they come here as raw counts and go on to the Mac's USB mouse unscaled: macOS's own settings set the feel.
///
/// Every connected peripheral that carries device information or battery service is logged with its services,
/// so a log shows what another brand's mouse exposes. Only HID++ is driven for now.
final class VendorMice: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = VendorMice()

    static let logitechService = CBUUID(string: "00010000-0000-1000-8000-011F2000046D")
    static let logitechReport = CBUUID(string: "00010001-0000-1000-8000-011F2000046D")
    /// Services nearly every Bluetooth mouse has, to find the ones iOS already holds connected.
    private static let lookups = [CBUUID(string: "180A"), CBUUID(string: "180F"), logitechService]

    private let queue = DispatchQueue(label: "henge.mouse.bt", qos: .userInteractive)
    private var central: CBCentralManager?
    // The rest is the queue's.
    private var wanted = false
    private var known: [UUID: CBPeripheral] = [:]
    private var drivers: [UUID: HIDPPMouse] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        queue.async { [self] in
            wanted = true
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue)
            } else {
                scan()
            }
        }
        // A diverted mouse does nothing for iOS, so hand it back whenever Henge leaves the screen.
        DispatchQueue.main.async { [self] in
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.suspend()
            })
            observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.suspend()
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.resume()
            })
        }
    }

    /// Hands every mouse back to iOS and lets go of it.
    func stop() {
        queue.sync {
            wanted = false
            releaseAll()
        }
        DispatchQueue.main.async { [self] in
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    private func suspend() {
        // Synchronous, so the writes are queued before the app is suspended. If iOS kills Henge before they go
        // out, turning the mouse off and on hands it back, since none of the diversion is persistent.
        queue.sync { if wanted { releaseAll() } }
    }

    private func resume() {
        queue.async { [self] in if wanted { scan() } }
    }

    private func releaseAll() {
        for driver in drivers.values { driver.restore() }
        drivers.removeAll()
        for p in known.values { central?.cancelPeripheralConnection(p) }
        known.removeAll()
        HardwareMouse.shared.releaseButtons()
    }

    private func scan() {
        guard let central, central.state == .poweredOn, wanted else { return }
        for service in Self.lookups {
            for p in central.retrieveConnectedPeripherals(withServices: [service]) where known[p.identifier] == nil {
                HengeLog.log("mouse-bt", "found \(p.name ?? p.identifier.uuidString) by \(service.uuidString)")
                known[p.identifier] = p
                p.delegate = self
                central.connect(p)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        HengeLog.log("mouse-bt", "Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn { scan() } else {
            drivers.removeAll()
            known.removeAll()
            HardwareMouse.shared.releaseButtons()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        HengeLog.log("mouse-bt", "connected to \(peripheral.name ?? "?")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        HengeLog.log("mouse-bt", "could not connect to \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "?")")
        known[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard known[peripheral.identifier] != nil else { return }
        HengeLog.log("mouse-bt", "\(peripheral.name ?? "?") disconnected: \(error?.localizedDescription ?? "-")")
        drivers[peripheral.identifier] = nil
        HardwareMouse.shared.releaseButtons()
        // A mouse that slept: this request waits for it to come back, and diversion is set up again then.
        if wanted { central.connect(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let list = peripheral.services ?? []
        HengeLog.log("mouse-bt", "\(peripheral.name ?? "?") services: \(list.map(\.uuid.uuidString)) \(error?.localizedDescription ?? "")")
        for s in list { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        HengeLog.log("mouse-bt", "\(peripheral.name ?? "?") \(service.uuid.uuidString): \(chars.map { "\($0.uuid.uuidString) props \($0.properties.rawValue)" })")
        guard service.uuid == Self.logitechService, let report = chars.first(where: { $0.uuid == Self.logitechReport }) else { return }
        let driver = HIDPPMouse(peripheral: peripheral, report: report, queue: queue)
        drivers[peripheral.identifier] = driver
        peripheral.setNotifyValue(true, for: report)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        HengeLog.log("mouse-bt", "\(peripheral.name ?? "?") notify \(characteristic.uuid.uuidString): \(characteristic.isNotifying) \(error?.localizedDescription ?? "")")
        guard characteristic.isNotifying, let driver = drivers[peripheral.identifier] else { return }
        driver.begin()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let driver = drivers[peripheral.identifier] else { return }
        driver.received(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { HengeLog.log("mouse-bt", "\(peripheral.name ?? "?") write failed: \(error.localizedDescription)") }
    }
}

/// One Logitech mouse over HID++ 2.0 on its Bluetooth LE channel. Everything runs on the Bluetooth queue.
///
/// Set up: find REPROG_CONTROLS_V4 (0x1B04), HIRES_WHEEL (0x2121) and THUMBWHEEL (0x2150) in the root feature; list
/// the controls; divert every divertable button; force raw motion onto one control that can carry it; ask for
/// analytics on the buttons that can't be diverted (left and right on most mice); and send both wheels to HID++.
/// A restore undoes all of it, and none of it is persistent, so turning the mouse off and on also undoes it.
final class HIDPPMouse {
    private enum Feature: UInt16 {
        case reprogControls = 0x1B04
        case hiresWheel = 0x2121
        case thumbwheel = 0x2150
        case wirelessStatus = 0x1D4B
    }

    private struct Control {
        let cid: UInt16
        let flags: UInt8   // 0x20 divertable
        let flags2: UInt8  // 0x01 raw XY, 0x02 force raw XY, 0x04 analytics key events
    }

    /// The software id in each request. A notification carries 0, so a reply is told from an event by it.
    private static let softwareID: UInt8 = 0x0A

    private let peripheral: CBPeripheral
    private let report: CBCharacteristic
    private let queue: DispatchQueue
    private var name: String { peripheral.name ?? "Logitech mouse" }

    /// On Bluetooth LE a HID++ message is 18 bytes: feature index, function and software id, then 16 bytes of
    /// parameters. It has no report id and no device index; the characteristic refuses a 19- or 20-byte write.
    private static let frameLength = 18
    private var pending: (feature: UInt8, function: UInt8, attempt: Int, done: (Data?) -> Void, payload: [UInt8])?
    private var timeout: DispatchWorkItem?
    private var framesLogged = 0

    private var reprogIndex: UInt8 = 0, wheelIndex: UInt8 = 0, thumbIndex: UInt8 = 0, statusIndex: UInt8 = 0
    private var controls: [Control] = []
    private var diverted: [UInt16] = []      // controls set to divert, raw XY or analytics, to undo
    private var analytics: [UInt16] = []
    private var heldDiverted: Set<UInt16> = []
    private var thumbRest: Int = 0, thumbPerDetent: Int = 0
    private var active = false

    init(peripheral: CBPeripheral, report: CBCharacteristic, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.report = report
        self.queue = queue
    }

    // MARK: Set up

    func begin() {
        guard pending == nil else { return }
        HengeLog.log("mouse-hidpp", "\(name): setting up; longest write \(peripheral.maximumWriteValueLength(for: .withResponse)) with response, \(peripheral.maximumWriteValueLength(for: .withoutResponse)) without")
        active = false
        diverted.removeAll()
        analytics.removeAll()
        heldDiverted.removeAll()
        feature(.wirelessStatus) { [self] index in
            statusIndex = index
            discover()
        }
    }

    private func discover() {
        feature(.reprogControls) { [self] index in
            reprogIndex = index
            feature(.hiresWheel) { [self] index in
                wheelIndex = index
                feature(.thumbwheel) { [self] index in
                    thumbIndex = index
                    HengeLog.log("mouse-hidpp", "\(name): controls at \(reprogIndex), wheel at \(wheelIndex), thumbwheel at \(thumbIndex)")
                    listControls()
                }
            }
        }
    }

    /// The root feature (index 0), function 0: a feature's index, 0 when the mouse lacks it.
    private func feature(_ id: Feature, then: @escaping (UInt8) -> Void) {
        request(0, 0, [UInt8(id.rawValue >> 8), UInt8(id.rawValue & 0xFF)]) { reply in
            then(reply.map { $0[0] } ?? 0)
        }
    }

    private func listControls() {
        guard reprogIndex != 0 else { return setUpWheels() }
        request(reprogIndex, 0, []) { [self] reply in
            let count = Int(reply?[0] ?? 0)
            controls.removeAll()
            readControl(0, of: count)
        }
    }

    private func readControl(_ i: Int, of count: Int) {
        guard i < count else { return divert() }
        request(reprogIndex, 1, [UInt8(i)]) { [self] reply in
            if let r = reply, r.count >= 9 {
                let control = Control(cid: UInt16(r[0]) << 8 | UInt16(r[1]), flags: r[4], flags2: r[8])
                controls.append(control)
                HengeLog.log("mouse-hidpp", String(format: "\(name): control 0x%02X flags 0x%02X flags2 0x%02X", control.cid, control.flags, control.flags2))
            }
            readControl(i + 1, of: count)
        }
    }

    private func divert() {
        var steps: [(UInt16, UInt8, UInt8)] = [] // cid, flags, analytics
        // Raw motion rides on one control. The gesture button (0xC3) carries it on an MX Master.
        let motion = controls.first { $0.cid == 0xC3 && $0.flags2 & 0x02 != 0 } ?? controls.first { $0.flags2 & 0x02 != 0 }
        for c in controls {
            var flags: UInt8 = 0
            if c.flags & 0x20 != 0 { flags |= 0x03 }                // divert, valid
            if c.cid == motion?.cid { flags |= 0x30 | 0xC0 }        // raw XY and force raw XY, valid
            let wantsAnalytics = c.flags & 0x20 == 0 && c.flags2 & 0x04 != 0
            if flags != 0 || wantsAnalytics { steps.append((c.cid, flags, wantsAnalytics ? 0x03 : 0)) }
        }
        if motion == nil { HengeLog.log("mouse-hidpp", "\(name): no control can carry raw motion; the pointer won't move") }
        apply(steps[...])
    }

    private func apply(_ steps: ArraySlice<(UInt16, UInt8, UInt8)>) {
        guard let step = steps.first else { return setUpWheels() }
        let (cid, flags, analyticsFlags) = step
        request(reprogIndex, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0, analyticsFlags]) { [self] reply in
            if reply != nil {
                diverted.append(cid)
                if analyticsFlags != 0 { analytics.append(cid) }
            }
            HengeLog.log("mouse-hidpp", String(format: "\(name): control 0x%02X flags 0x%02X analytics 0x%02X: %@", cid, flags, analyticsFlags, reply == nil ? "refused" : "set"))
            apply(steps.dropFirst())
        }
    }

    private func setUpWheels() {
        let finish = { [self] in
            active = true
            HengeLog.log("mouse-hidpp", "\(name): passing through (\(diverted.count) controls, wheel \(wheelIndex != 0), thumbwheel \(thumbIndex != 0))")
        }
        let thumb = { [self] in
            guard thumbIndex != 0 else { return finish() }
            // Info: native resolution, diverted resolution (increments per turn).
            request(thumbIndex, 0, []) { [self] info in
                let diverted = info.map { Int($0[2]) << 8 | Int($0[3]) } ?? 0
                thumbPerDetent = max(1, diverted / 24) // a wheel's detents per turn, so a turn scrolls about as far
                request(thumbIndex, 2, [0x01, 0x00]) { _ in finish() }
            }
        }
        guard wheelIndex != 0 else { return thumb() }
        request(wheelIndex, 2, [0x01]) { _ in thumb() } // HID++ target, low resolution: one count per detent
    }

    /// Hands the mouse back to iOS. Writes without waiting for answers, so it works on the way out of the app.
    func restore() {
        guard !diverted.isEmpty || active else { return }
        active = false
        for cid in diverted {
            let analyticsFlags: UInt8 = analytics.contains(cid) ? 0x02 : 0
            send(reprogIndex, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), 0xA2, 0, 0, analyticsFlags])
        }
        if wheelIndex != 0 { send(wheelIndex, 2, [0x00]) }
        if thumbIndex != 0 { send(thumbIndex, 2, [0x00, 0x00]) }
        diverted.removeAll()
        analytics.removeAll()
        heldDiverted.removeAll()
        HengeLog.log("mouse-hidpp", "\(name): handed back to iOS")
    }

    // MARK: Requests

    private func request(_ feature: UInt8, _ function: UInt8, _ params: [UInt8], attempt: Int = 0, done: @escaping (Data?) -> Void) {
        pending = (feature, function, attempt, done, params)
        send(feature, function, params)
        let item = DispatchWorkItem { [weak self] in self?.timedOut() }
        timeout = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func timedOut() {
        guard let p = pending else { return }
        pending = nil
        if p.attempt == 0 {
            HengeLog.log("mouse-hidpp", "\(name): no answer; asking again")
            request(p.feature, p.function, p.payload, attempt: 1, done: p.done)
        } else {
            HengeLog.log("mouse-hidpp", "\(name): no answer to feature \(p.feature) function \(p.function)")
            p.done(nil)
        }
    }

    private func send(_ feature: UInt8, _ function: UInt8, _ params: [UInt8]) {
        var frame: [UInt8] = [feature, function << 4 | Self.softwareID] + params
        frame += [UInt8](repeating: 0, count: max(0, Self.frameLength - frame.count))
        logFrame("out", frame)
        peripheral.writeValue(Data(frame), for: report, type: .withResponse)
    }

    func received(_ data: Data) {
        let bytes = [UInt8](data)
        logFrame("in", bytes)
        guard bytes.count >= 2 else { return }
        let feature = bytes[0], fnsw = bytes[1]
        let params = Data(bytes.dropFirst(2))

        // An error: 0xFF, then the request's feature index and function byte, then the error code.
        if feature == 0xFF, let p = pending, bytes.count >= 4, bytes[1] == p.feature, bytes[2] >> 4 == p.function {
            HengeLog.log("mouse-hidpp", String(format: "\(name): error 0x%02X from feature %d function %d", bytes[3], p.feature, p.function))
            finish(nil)
            return
        }
        if fnsw & 0x0F == Self.softwareID, let p = pending, feature == p.feature, fnsw >> 4 == p.function {
            finish(params)
            return
        }
        // The mouse asks to be set up again after it reconnects or wakes (wireless status: reconfiguration needed).
        if fnsw & 0x0F == 0, feature == statusIndex, statusIndex != 0, params.count >= 2, params[1] == 1 {
            HengeLog.log("mouse-hidpp", "\(name): asks to be set up again")
            begin()
            return
        }
        if fnsw & 0x0F == 0, feature != 0, active { event(feature, fnsw >> 4, [UInt8](params)) }
    }

    private func finish(_ reply: Data?) {
        timeout?.cancel()
        guard let p = pending else { return }
        pending = nil
        p.done(reply)
    }

    private func logFrame(_ way: String, _ bytes: [UInt8]) {
        guard framesLogged < 64 else { return }
        framesLogged += 1
        HengeLog.log("mouse-hidpp", "\(way) " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    // MARK: Events

    private func event(_ feature: UInt8, _ kind: UInt8, _ p: [UInt8]) {
        let mouse = HardwareMouse.shared
        switch (feature, kind) {
        case (reprogIndex, 1) where p.count >= 4: // raw motion: dx, dy, signed, big-endian, Y down
            let dx = Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1]))
            let dy = Int16(bitPattern: UInt16(p[2]) << 8 | UInt16(p[3]))
            mouse.vendorMoved(Int32(dx), Int32(dy))
        case (reprogIndex, 0): // diverted buttons: up to four controls held now
            var now: Set<UInt16> = []
            for i in stride(from: 0, to: min(8, p.count - 1), by: 2) {
                let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                if cid != 0 { now.insert(cid) }
            }
            for cid in now.subtracting(heldDiverted) { press(cid, true) }
            for cid in heldDiverted.subtracting(now) { press(cid, false) }
            heldDiverted = now
        case (reprogIndex, 2): // analytics: control and event pairs, 1 pressed and 0 released
            for i in stride(from: 0, to: p.count - 2, by: 3) {
                let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                guard cid != 0 else { break }
                press(cid, p[i + 2] & 0x01 != 0)
            }
        case (wheelIndex, 0) where p.count >= 3: // flags, then a signed big-endian delta; positive is away from the user
            let delta = Int16(bitPattern: UInt16(p[1]) << 8 | UInt16(p[2]))
            mouse.vendorScrolled(wheel: Int32(delta), pan: 0)
        case (thumbIndex, 0) where p.count >= 2: // rotation, signed big-endian
            thumbRest += Int(Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1])))
            let detents = thumbRest / thumbPerDetent
            thumbRest -= detents * thumbPerDetent
            if detents != 0 { mouse.vendorScrolled(wheel: 0, pan: Int32(detents)) }
        default:
            break
        }
    }

    /// A control id as the USB mouse's button bit: left, right, middle, back, forward.
    private func press(_ cid: UInt16, _ pressed: Bool) {
        let bit: UInt32
        switch cid {
        case 0x50: bit = 0
        case 0x51: bit = 1
        case 0x52: bit = 2
        case 0x53: bit = 3
        case 0x56: bit = 4
        default:
            HengeLog.log("mouse-hidpp", String(format: "\(name): control 0x%02X %@ (not mapped)", cid, pressed ? "down" : "up"))
            return
        }
        HardwareMouse.shared.vendorButton(bit, pressed)
    }
}
