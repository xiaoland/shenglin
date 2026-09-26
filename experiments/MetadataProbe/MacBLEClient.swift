import CoreBluetooth
import Foundation

let serviceID = CBUUID(string: "2D0F599A-4B67-4D91-A754-B19871D7503B")
let commandID = CBUUID(string: "779777EF-1D35-4658-935A-A43718B81CB6")
guard CommandLine.arguments.count >= 2 else { fatalError("Usage: MacBLEClient <iPad console log> [delay seconds|--interactive]") }
let log = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let pattern = try NSRegularExpression(pattern: #"BLE .* TOKEN ([0-9A-F-]+)"#)
guard let match = pattern.matches(in: log, range: NSRange(log.startIndex..., in: log)).last,
      let range = Range(match.range(at: 1), in: log) else { fatalError("Missing BLE token") }
let token = String(log[range])
let interactive = CommandLine.arguments.contains("--interactive")
let firstDelay = CommandLine.arguments.count >= 3 ? (Double(CommandLine.arguments[2]) ?? 25) : 25

final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var peripheral: CBPeripheral?
    var characteristic: CBCharacteristic?
    func start() { manager = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("MAC_STATE \(central.state.rawValue)")
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [serviceID]) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        print("DISCOVERED rssi=\(RSSI)")
        central.stopScan()
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("CONNECTED \(Date().timeIntervalSince1970)")
        peripheral.delegate = self
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("CONNECT_FAILED \(String(describing: error))")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("DISCONNECTED \(Date().timeIntervalSince1970) \(String(describing: error))")
        characteristic = nil
        central.connect(peripheral)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("SERVICES_ERROR \(error)"); return }
        for service in peripheral.services ?? [] where service.uuid == serviceID {
            peripheral.discoverCharacteristics([commandID], for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { print("CHARACTERISTICS_ERROR \(error)"); return }
        characteristic = service.characteristics?.first(where: { $0.uuid == commandID })
        print("READY \(Date().timeIntervalSince1970)")
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("WRITE_ACK \(Date().timeIntervalSince1970) \(String(describing: error))")
    }
    func send(_ command: String) {
        guard let peripheral, let characteristic else { print("NOT_READY"); return }
        let text = "\(token) \(command) \(Date().timeIntervalSince1970 + 4)"
        peripheral.writeValue(Data(text.utf8), for: characteristic, type: .withResponse)
        print("SENT \(Date().timeIntervalSince1970) \(command)")
    }
}
let client = Client()
client.start()
if interactive {
    DispatchQueue.global().async {
        while let line = readLine() {
            DispatchQueue.main.async {
                if line == "ping" || line == "volume" || line == "stop" { client.send(line) }
                if line == "quit" { exit(0) }
            }
        }
    }
    RunLoop.main.run()
} else {
    DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) { client.send("ping") }
    DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay + 5) { client.send("volume") }
    RunLoop.main.run(until: Date().addingTimeInterval(firstDelay + 20))
}
