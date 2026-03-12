import CoreBluetooth
import Foundation
import HowlCore

@MainActor
final class CoyoteBluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: String {
        case unavailable = "Unavailable"
        case disconnected = "Disconnected"
        case scanning = "Scanning"
        case connecting = "Connecting"
        case discovering = "Discovering Services"
        case subscribing = "Subscribing"
        case syncing = "Syncing Parameters"
        case ready = "Ready"
    }

    private enum PendingWriteIntent {
        case initialSync
        case parameterUpdate
        case pulse
    }

    @Published var state: ConnectionState = .unavailable
    @Published var lastSeenDeviceName = "None"
    @Published var stagedPacketHex = ""
    @Published var lastNotifyHex = ""
    @Published var batteryLevel: Int?
    @Published var devicePowerA: Int?
    @Published var devicePowerB: Int?
    @Published var lastNotifySummary = "No notify frames yet."
    @Published var lastWriteHex = ""
    @Published var lastWriteSummary = "No packets sent yet."
    @Published var sentPulsePacketCount = 0
    @Published var queuedPulsePacketCount = 0
    @Published var notifyFrameCount = 0
    @Published var lastError: String?

    var isReady: Bool {
        state == .ready
    }

    private let supportedDeviceNames = ["47L121000"]
    private let scanTimeoutSeconds: Double = 10
    private let batteryPollIntervalSeconds: Double = 60.02
    private let clientConfigDescriptorUUID = CBUUID(string: "2902")
    private let mainServiceUUID = CBUUID(nsuuid: Coyote3Protocol.mainServiceUUID)
    private let batteryServiceUUID = CBUUID(nsuuid: Coyote3Protocol.batteryServiceUUID)
    private let writeCharacteristicUUID = CBUUID(nsuuid: Coyote3Protocol.writeCharacteristicUUID)
    private let notifyCharacteristicUUID = CBUUID(nsuuid: Coyote3Protocol.notifyCharacteristicUUID)
    private let batteryCharacteristicUUID = CBUUID(nsuuid: Coyote3Protocol.batteryCharacteristicUUID)

    private var desiredLimitA = 20
    private var desiredLimitB = 20
    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var scanTimeoutTask: Task<Void, Never>?
    private var batteryPollTask: Task<Void, Never>?
    private var pendingWriteIntent: PendingWriteIntent?
    private var notifySubscriptionRequested = false
    private var queuedPulsePacket: Data?
    private var queuedResponseWrite: (data: Data, intent: PendingWriteIntent)?

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

        resetSession(clearPeripheral: true)
        lastError = nil
        batteryLevel = nil
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        scheduleScanTimeout()
    }

    func disconnect() {
        scanTimeoutTask?.cancel()
        batteryPollTask?.cancel()
        central.stopScan()
        if let connectedPeripheral {
            central.cancelPeripheralConnection(connectedPeripheral)
        } else {
            resetSession(clearPeripheral: true)
            state = central.state == .poweredOn ? .disconnected : .unavailable
        }
    }

    func updateDesiredLimits(limitA: Int, limitB: Int) {
        desiredLimitA = limitA
        desiredLimitB = limitB

        guard isReady else { return }
        sendParameters(markAsInitialSync: false)
    }

    func stage(_ packet: Data) {
        stagedPacketHex = packet.hexString
    }

    func clearStagedPacket() {
        stagedPacketHex = ""
    }

    func sendLivePacket(_ packet: Data) {
        stage(packet)
        guard isReady else { return }
        write(packet, intent: .pulse)
    }

    private func scheduleScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(scanTimeoutSeconds))
            guard !Task.isCancelled, state == .scanning else { return }
            central.stopScan()
            state = .disconnected
            lastError = "Timed out while searching for a Coyote 3."
        }
    }

    private func sendParameters(markAsInitialSync: Bool) {
        let packet = Coyote3Protocol.parameterPacket(
            limitA: desiredLimitA,
            limitB: desiredLimitB
        )
        write(packet, intent: markAsInitialSync ? .initialSync : .parameterUpdate)
    }

    private func write(_ data: Data, intent: PendingWriteIntent) {
        guard let connectedPeripheral, let writeCharacteristic else {
            if intent != .pulse {
                lastError = "Coyote 3 write characteristic is not ready yet."
            }
            return
        }

        let properties = writeCharacteristic.properties
        let writeType: CBCharacteristicWriteType
        switch intent {
        case .initialSync, .parameterUpdate:
            if properties.contains(.write) {
                guard pendingWriteIntent == nil else {
                    queuedResponseWrite = (data, intent)
                    lastWriteSummary = "Queued a control packet while waiting for the previous write response."
                    return
                }
                writeType = .withResponse
                pendingWriteIntent = intent
            } else if properties.contains(.writeWithoutResponse) {
                writeType = .withoutResponse
                pendingWriteIntent = nil
            } else {
                lastError = "The Coyote 3 write characteristic does not accept writes."
                return
            }
        case .pulse:
            if properties.contains(.writeWithoutResponse) {
                guard connectedPeripheral.canSendWriteWithoutResponse else {
                    queuedPulsePacket = data
                    queuedPulsePacketCount += 1
                    lastWriteSummary = "Queued latest live pulse batch because BLE backpressure is active."
                    return
                }
                writeType = .withoutResponse
                pendingWriteIntent = nil
                queuedPulsePacket = nil
            } else if properties.contains(.write) {
                guard pendingWriteIntent == nil else {
                    queuedResponseWrite = (data, intent)
                    lastWriteSummary = "Queued latest live pulse batch while waiting for a write response."
                    return
                }
                writeType = .withResponse
                pendingWriteIntent = intent
            } else {
                lastError = "The Coyote 3 write characteristic does not accept pulse writes."
                return
            }
        }

        connectedPeripheral.writeValue(data, for: writeCharacteristic, type: writeType)
        recordWrite(data, intent: intent, writeType: writeType)

        if writeType == .withoutResponse && intent == .initialSync {
            finishInitialSync()
        }
    }

    private func finishInitialSync() {
        state = .ready
        lastError = nil
        readBatteryLevel()
        startBatteryPolling()
    }

    private func readBatteryLevel() {
        guard let connectedPeripheral, let batteryCharacteristic else { return }
        connectedPeripheral.readValue(for: batteryCharacteristic)
    }

    private func startBatteryPolling() {
        batteryPollTask?.cancel()
        batteryPollTask = Task { [weak self] in
            guard let self else { return }
            readBatteryLevel()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(batteryPollIntervalSeconds))
                guard !Task.isCancelled else { return }
                readBatteryLevel()
            }
        }
    }

    private func resetSession(clearPeripheral: Bool) {
        scanTimeoutTask?.cancel()
        batteryPollTask?.cancel()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        batteryCharacteristic = nil
        pendingWriteIntent = nil
        notifySubscriptionRequested = false
        queuedPulsePacket = nil
        queuedResponseWrite = nil
        lastNotifyHex = ""
        batteryLevel = nil
        devicePowerA = nil
        devicePowerB = nil
        lastNotifySummary = "No notify frames yet."
        lastWriteHex = ""
        lastWriteSummary = "No packets sent yet."
        sentPulsePacketCount = 0
        queuedPulsePacketCount = 0
        notifyFrameCount = 0
        if clearPeripheral {
            connectedPeripheral = nil
        }
    }

    private func recordWrite(_ data: Data, intent: PendingWriteIntent, writeType: CBCharacteristicWriteType) {
        lastWriteHex = data.hexString
        let responseLabel = writeType == .withResponse ? "with response" : "without response"
        switch intent {
        case .initialSync:
            lastWriteSummary = "Synced Coyote parameters (\(responseLabel))."
        case .parameterUpdate:
            lastWriteSummary = "Updated Coyote parameters (\(responseLabel))."
        case .pulse:
            sentPulsePacketCount += 1
            lastWriteSummary = "Sent live pulse batch #\(sentPulsePacketCount) (\(responseLabel))."
        }
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
            resetSession(clearPeripheral: true)
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
        scanTimeoutTask?.cancel()
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetSession(clearPeripheral: false)
        connectedPeripheral = peripheral
        state = .discovering
        peripheral.discoverServices([mainServiceUUID, batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetSession(clearPeripheral: true)
        state = .disconnected
        lastError = error?.localizedDescription ?? "Failed to connect to the Coyote 3."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetSession(clearPeripheral: true)
        state = central.state == .poweredOn ? .disconnected : .unavailable
        if let error {
            lastError = error.localizedDescription
        }
    }
}

extension CoyoteBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }

        guard let services = peripheral.services else {
            lastError = "No BLE services were discovered on the Coyote 3."
            disconnect()
            return
        }

        let mainService = services.first { $0.uuid == mainServiceUUID }
        if let mainService {
            peripheral.discoverCharacteristics([writeCharacteristicUUID, notifyCharacteristicUUID], for: mainService)
        } else {
            lastError = "The connected device is missing the Coyote 3 control service."
            disconnect()
            return
        }

        if let batteryService = services.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics([batteryCharacteristicUUID], for: batteryService)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }

        guard let characteristics = service.characteristics else { return }

        if service.uuid == mainServiceUUID {
            writeCharacteristic = characteristics.first { $0.uuid == writeCharacteristicUUID }
            notifyCharacteristic = characteristics.first { $0.uuid == notifyCharacteristicUUID }

            guard let notifyCharacteristic else {
                lastError = "The Coyote 3 notify characteristic could not be found."
                disconnect()
                return
            }

            guard writeCharacteristic != nil else {
                lastError = "The Coyote 3 write characteristic could not be found."
                disconnect()
                return
            }

            if !notifySubscriptionRequested {
                notifySubscriptionRequested = true
                state = .subscribing
                peripheral.setNotifyValue(true, for: notifyCharacteristic)
            }
        } else if service.uuid == batteryServiceUUID {
            batteryCharacteristic = characteristics.first { $0.uuid == batteryCharacteristicUUID }
            if isReady {
                readBatteryLevel()
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }

        guard characteristic.uuid == notifyCharacteristicUUID else { return }
        guard characteristic.isNotifying else {
            lastError = "The Coyote 3 notify channel did not stay enabled."
            disconnect()
            return
        }

        state = .syncing
        sendParameters(markAsInitialSync: true)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            return
        }

        guard let data = characteristic.value else { return }

        if characteristic.uuid == batteryCharacteristicUUID {
            batteryLevel = data.first.map(Int.init)
            return
        }

        if characteristic.uuid == notifyCharacteristicUUID {
            lastNotifyHex = data.hexString
            notifyFrameCount += 1
            if let status = Coyote3Protocol.decodeStatusPacket(data) {
                devicePowerA = status.powerA
                devicePowerB = status.powerB
                let modeLabel = status.shouldApplyPowerEcho ? "device-applied" : "strength-sync"
                lastNotifySummary = "Status #\(notifyFrameCount): A \(status.powerA) / B \(status.powerB) [\(modeLabel)]"
            } else {
                lastNotifySummary = "Notify #\(notifyFrameCount): unrecognized frame \(data.hexString)"
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let intent = pendingWriteIntent
        pendingWriteIntent = nil

        if let error {
            lastError = error.localizedDescription
            if intent == .initialSync {
                disconnect()
            }
            return
        }

        guard characteristic.uuid == writeCharacteristicUUID else { return }

        if intent == .initialSync {
            finishInitialSync()
        }

        if let queuedResponseWrite {
            self.queuedResponseWrite = nil
            write(queuedResponseWrite.data, intent: queuedResponseWrite.intent)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isReady, let queuedPulsePacket else { return }
        write(queuedPulsePacket, intent: .pulse)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
