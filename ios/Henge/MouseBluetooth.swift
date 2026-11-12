import CoreBluetooth
import Foundation

/// Probe: what an app can see of a Bluetooth mouse the iPhone has paired.
///
/// On an iPhone without AssistiveTouch, GameController announces a mouse but passes on none of its input:
/// polled state never changes and there is no pointer lock. A Logitech mouse also carries Logitech's own
/// protocol (HID++) beside standard HID, which can report a mouse's motion and buttons to software. This
/// logs which of the mouse's Bluetooth services an app can reach, to learn whether that is a way in.
final class MouseBluetoothProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = MouseBluetoothProbe()

    /// Standard HID over GATT, battery, device information, and Logitech's HID++ service.
    private static let services = [CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A"),
                                   CBUUID(string: "00010000-0000-1000-8000-011F2000046D")]
    private var central: CBCentralManager?
    private var peripherals: [CBPeripheral] = []
    private var ran = false

    func run() {
        guard !ran else { return }
        ran = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        HengeLog.log("bt-probe", "Bluetooth state \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        for service in Self.services {
            let found = central.retrieveConnectedPeripherals(withServices: [service])
            HengeLog.log("bt-probe", "connected with \(service.uuidString): \(found.map { $0.name ?? $0.identifier.uuidString })")
            for p in found where !peripherals.contains(where: { $0.identifier == p.identifier }) {
                peripherals.append(p)
                p.delegate = self
                central.connect(p)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        HengeLog.log("bt-probe", "connected to \(peripheral.name ?? "?")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        HengeLog.log("bt-probe", "could not connect to \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "?")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let list = peripheral.services ?? []
        HengeLog.log("bt-probe", "\(peripheral.name ?? "?") services: \(list.map(\.uuid.uuidString)) \(error?.localizedDescription ?? "")")
        for s in list { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = (service.characteristics ?? []).map { "\($0.uuid.uuidString) props \($0.properties.rawValue)" }
        HengeLog.log("bt-probe", "\(peripheral.name ?? "?") \(service.uuid.uuidString): \(chars) \(error?.localizedDescription ?? "")")
    }
}
