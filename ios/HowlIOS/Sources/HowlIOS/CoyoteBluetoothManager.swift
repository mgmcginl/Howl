import CoreBluetooth
import Foundation

@MainActor
final class CoyoteBluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: String {
        case unavailable = "Unavailable"
        case disconnected = "Disconnected"
        case scanning = "Scanning"
        case connecting = "Connecting"
        case connected = "Connected"
    }

    @Published var state: ConnectionState = .unavailable
    @Published var lastSeenDeviceName = "None"
    @Published var stagedPacketHex = ""
    @Published var lastError: String?

    private let supportedDeviceNames = ["47L121000", "D-LAB ESTIM01"]
    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func connectOrScan() {
        guard central.state == .poweredOn else {
            state = .unavailable
            lastError = "Bluetooth is not powered on."
            return
        }

        lastError = nil
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func disconnect() {
        central.stopScan()
        if let connectedPeripheral {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        state = .disconnected
    }

    func stage(_ packet: Data) {
        stagedPacketHex = packet.map { String(format: "%02X", $0) }.joined()
    }

    func clearStagedPacket() {
        stagedPacketHex = ""
    }
}

extension CoyoteBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .unavailable {
                state = .disconnected
            }
        default:
            state = .unavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let candidateName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"
        guard supportedDeviceNames.contains(candidateName) else { return }

        lastSeenDeviceName = candidateName
        connectedPeripheral = peripheral
        state = .connecting
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        connectedPeripheral = peripheral
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        lastError = error?.localizedDescription ?? "Failed to connect."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        if let error {
            lastError = error.localizedDescription
        }
    }
}

extension CoyoteBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
        }
    }
}
