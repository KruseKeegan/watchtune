import CoreBluetooth
import Foundation

/// Bluetooth link to the Ollee Watch's Forge BLE service:
///   service C6FB0001-A37D-40AC-89BE-887D25E1F5B3
///   RX  C6FB0002-... (phone writes, <= 20 bytes per write)
///   TX  C6FB0003-... (watch notifies)
/// Remembers the chosen watch and reconnects to it, in the background too
/// (bluetooth-central background mode + state restoration).
/// CoreBluetooth calls back on the main queue.
final class WatchLink: NSObject, ObservableObject {
    static let service = CBUUID(string: "C6FB0001-A37D-40AC-89BE-887D25E1F5B3")

    @Published private(set) var status = "Starting Bluetooth…"
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var found: [CBPeripheral] = []

    /// A message from the watch (one notification, as a byte string)
    var onReceive: ((String) -> Void)?
    /// The link is ready to send
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var queue: [Data] = []
    private var awaitingWrite = false
    private let savedKey = "watchPeripheralID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "watchtune.central"])
    }

    var hasSavedWatch: Bool { UserDefaults.standard.string(forKey: savedKey) != nil }

    // MARK: Choosing a watch

    func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        scanning = true
        status = "Looking for watches…"
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
        if !connected { status = found.isEmpty ? "No watch found" : "Pick your watch" }
    }

    func choose(_ p: CBPeripheral) {
        stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        connect(p)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rx = nil
        connected = false
        status = "Not connected"
    }

    // MARK: Sending

    /// Queues one write (<= 20 bytes; each character is one byte).
    func send(_ message: String) {
        guard let data = message.data(using: .isoLatin1) else { return }
        queue.append(data)
        pump()
    }

    private func pump() {
        guard let p = peripheral, let rx = rx, p.state == .connected else { return }
        while !queue.isEmpty && !awaitingWrite {
            if rx.properties.contains(.write) {
                awaitingWrite = true
                p.writeValue(queue.removeFirst(), for: rx, type: .withResponse)
            } else {
                guard p.canSendWriteWithoutResponse else { return }  // resumes in peripheralIsReady
                p.writeValue(queue.removeFirst(), for: rx, type: .withoutResponse)
            }
        }
    }

    // MARK: Connecting

    private func reconnect() {
        if let p = peripheral { connect(p); return }
        if let s = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        // The Ollee app usually has the watch connected already
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            choose(p)
            return
        }
        status = "Tap Find watch"
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = "Connecting to \(p.name ?? "watch")…"
        // A pending connect never times out, so this also waits for the
        // watch to come back in range
        central.connect(p, options: nil)
    }

    private func linkLost(_ p: CBPeripheral, _ why: String) {
        guard p == peripheral else { return }
        connected = false
        rx = nil
        awaitingWrite = false
        queue.removeAll()
        status = why
        if hasSavedWatch { central.connect(p, options: nil) }
    }
}

extension WatchLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: reconnect()
        case .unauthorized: status = "Allow Bluetooth for WatchTune in Settings"
        case .poweredOff: status = "Bluetooth is off"
        default: status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard p.name != nil, !found.contains(where: { $0.identifier == p.identifier }) else { return }
        found.append(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Connected, finding the Forge service…"
        p.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        linkLost(p, "Couldn't connect, retrying…")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        linkLost(p, "Watch disconnected, waiting for it…")
    }
}

extension WatchLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            status = "This device has no Forge service. Pick your Ollee Watch."
            return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            let id = c.uuid.uuidString.uppercased()
            if id.hasPrefix("C6FB0002") { rx = c }
            if id.hasPrefix("C6FB0003") { p.setNotifyValue(true, for: c) }
        }
        guard rx != nil else {
            status = "Forge service has no RX characteristic"
            return
        }
        connected = true
        status = "Connected to \(p.name ?? "watch")"
        onReady?()
        pump()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value, !data.isEmpty else { return }
        onReceive?(String(decoding: data, as: UTF8.self))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        awaitingWrite = false
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }
}
