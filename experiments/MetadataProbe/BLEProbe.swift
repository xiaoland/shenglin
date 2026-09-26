import CoreBluetooth
import Foundation
import Security
import UIKit

@MainActor final class BLEProbe: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: "2D0F599A-4B67-4D91-A754-B19871D7503B")
    static let commandID = CBUUID(string: "779777EF-1D35-4658-935A-A43718B81CB6")
    private var manager: CBPeripheralManager?
    private lazy var token = BLEProbe.savedToken()
    private var busy = false
    private var restoredServices = false
    private let stopping = CommandLine.arguments.contains("--ble-stop")
    private func stop() {
        UserDefaults.standard.set(false, forKey: "BLEProbeEnabled")
        manager?.stopAdvertising()
        manager?.removeAllServices()
        note("STOPPED")
    }
    private func note(_ message: String) {
        FileHandle.standardOutput.write(Data("BLE \(Date().timeIntervalSince1970) state=\(UIApplication.shared.applicationState.rawValue) \(message)\n".utf8))
    }
    private static func savedToken() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: "MetadataProbeBLEToken",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8) { return value }
        precondition(status == errSecItemNotFound, "Cannot read BLE token from keychain: \(status)")
        let value = UUID().uuidString
        var entry = query
        entry.removeValue(forKey: kSecReturnData as String)
        entry.removeValue(forKey: kSecMatchLimit as String)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        entry[kSecValueData as String] = Data(value.utf8)
        precondition(SecItemAdd(entry as CFDictionary, nil) == errSecSuccess, "Cannot save BLE token")
        return value
    }
    override init() {
        super.init()
        if stopping { UserDefaults.standard.set(false, forKey: "BLEProbeEnabled") }
        if CommandLine.arguments.contains("--ble") {
            UserDefaults.standard.set(true, forKey: "BLEProbeEnabled")
        }
        if stopping || UserDefaults.standard.bool(forKey: "BLEProbeEnabled") {
            note("TOKEN \(token)")
            manager = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionRestoreIdentifierKey: "MetadataProbePeripheral"])
        }
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        note("STATE \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else { return }
        if stopping {
            stop()
            return
        }
        if restoredServices {
            if !peripheral.isAdvertising { peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]]) }
            return
        }
        let characteristic = CBMutableCharacteristic(type: Self.commandID, properties: [.write], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        note("SERVICE \(error.map(String.init(describing:)) ?? "ready")")
        if error == nil { peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]]) }
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        note("ADVERTISING \(error.map(String.init(describing:)) ?? "ready")")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.commandID, let data = request.value,
                  data.count <= 192,
                  let command = experimentCommand(data, token: token, now: Date().timeIntervalSince1970),
                  command == "ping" || command == "volume" || command == "stop" else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            note("RECEIVED \(command)")
            peripheral.respond(to: request, withResult: .success)
            if command == "stop" { stop(); continue }
            if command == "volume" && !busy {
                busy = true
                Task { @MainActor in
                    let result = await testPrivateVolume()
                    note("VOLUME_RESULT \(result)")
                    busy = false
                }
            }
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        restoredServices = !(dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBService] ?? []).isEmpty
        note("RESTORED \(dict.keys.sorted())")
    }
}
