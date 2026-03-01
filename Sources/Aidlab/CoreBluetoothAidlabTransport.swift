@preconcurrency import CoreBluetooth
import Foundation

final class CoreBluetoothAidlabTransport: NSObject, AidlabTransport, CoreBluetoothLifecycleForwarding, CBPeripheralDelegate, @unchecked Sendable {
    var rssi: NSNumber

    let peripheral: CBPeripheral
    var address: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var mtuSize: Int { peripheral.maximumWriteValueLength(for: .withResponse) }

    var onRSSIRead: (@Sendable (NSNumber) -> Void)?

    var onDisconnect: ((DisconnectReason, Error?) -> Void)?

    private let centralManagerProvider: () -> CBCentralManager?

    private struct NotifyHandler {
        let onData: (Data) -> Void
        let onError: (Error) -> Void
    }

    private var connectCompletion: ((Result<Void, Error>) -> Void)?
    private var manualDisconnectRequested = false
    private var didEmitDisconnect = false

    private var characteristicsByUuid: [CBUUID: CBCharacteristic] = [:]
    private var pendingServicesCount = 0
    private var didReportConnected = false

    private var readCompletionsByUuid: [CBUUID: [(Result<Data, Error>) -> Void]] = [:]
    private var writeCompletionsByUuid: [CBUUID: [(Result<Void, Error>) -> Void]] = [:]

    private var notifyByUuid: [CBUUID: NotifyHandler] = [:]

    init(
        peripheral: CBPeripheral,
        rssi: NSNumber,
        centralManagerProvider: @escaping () -> CBCentralManager?
    ) {
        self.peripheral = peripheral
        self.centralManagerProvider = centralManagerProvider
        self.rssi = rssi
        super.init()
    }

    convenience init(
        peripheral: CBPeripheral,
        rssi: NSNumber,
        centralManager: CBCentralManager
    ) {
        self.init(peripheral: peripheral, rssi: rssi, centralManagerProvider: { centralManager })
    }

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        if connectCompletion != nil {
            completion(.failure(AidlabError(message: "Already connecting")))
            return
        }

        resetConnectionState()
        manualDisconnectRequested = false
        didEmitDisconnect = false
        didReportConnected = false
        peripheral.delegate = self

        guard let centralManager = centralManagerProvider() else {
            completion(.failure(AidlabError(message: "Central manager unavailable")))
            return
        }

        connectCompletion = completion
        centralManager.connect(peripheral)
    }

    func disconnect() {
        manualDisconnectRequested = true
        guard let centralManager = centralManagerProvider() else {
            emitDisconnect(.unknownError, error: nil)
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func readCharacteristic(_ uuid: CBUUID, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let characteristic = characteristicsByUuid[uuid] else {
            completion(.failure(AidlabError(message: "Characteristic \(uuid.uuidString) unavailable")))
            return
        }

        readCompletionsByUuid[uuid, default: []].append(completion)
        peripheral.readValue(for: characteristic)
    }

    func writeCharacteristic(
        _ uuid: CBUUID,
        data: Data,
        withResponse: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let characteristic = characteristicsByUuid[uuid] else {
            completion(.failure(AidlabError(message: "Characteristic \(uuid.uuidString) unavailable")))
            return
        }

        if !withResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            completion(.success(()))
            return
        }

        writeCompletionsByUuid[uuid, default: []].append(completion)
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func startNotifications(_ uuid: CBUUID, onData: @escaping (Data) -> Void, onError: @escaping (Error) -> Void) {
        guard let characteristic = characteristicsByUuid[uuid] else {
            onError(AidlabError(message: "Characteristic \(uuid.uuidString) unavailable"))
            return
        }

        notifyByUuid[uuid] = NotifyHandler(onData: onData, onError: onError)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func stopNotifications(_ uuid: CBUUID) {
        notifyByUuid.removeValue(forKey: uuid)
        if peripheral.state == .connected, let characteristic = characteristicsByUuid[uuid] {
            peripheral.setNotifyValue(false, for: characteristic)
        }
    }

    // MARK: - CoreBluetoothLifecycleForwarding

    func notifyDidConnect() {
        resetConnectionState()
        manualDisconnectRequested = false
        didReportConnected = false
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func notifyDidFailToConnect(error: Error?) {
        let resolvedError = error ?? AidlabError(message: "Fail to connect")
        connectCompletion?(.failure(resolvedError))
        connectCompletion = nil
    }

    func notifyDidDisconnect(error: Error?) {
        let reason: DisconnectReason =
            manualDisconnectRequested ? .appDisconnected : mapDisconnectReason(error: error)
        manualDisconnectRequested = false
        emitDisconnect(reason, error: error)
    }

    private func emitDisconnect(_ reason: DisconnectReason, error: Error?) {
        if didEmitDisconnect {
            return
        }
        didEmitDisconnect = true

        // Tell the SDK about the disconnect first. This makes `didDisconnect` the primary
        // signal for a connection teardown and avoids spamming `didReceiveError` with
        // secondary failures caused by the disconnect (in-flight reads/writes, etc.).
        onDisconnect?(reason, error)

        let disconnectedError = error ?? AidlabError(message: "Disconnected")

        if let connectCompletion {
            connectCompletion(.failure(disconnectedError))
            self.connectCompletion = nil
        }

        for (_, completions) in readCompletionsByUuid {
            for completion in completions {
                completion(.failure(disconnectedError))
            }
        }
        readCompletionsByUuid.removeAll(keepingCapacity: false)

        for (_, completions) in writeCompletionsByUuid {
            for completion in completions {
                completion(.failure(disconnectedError))
            }
        }
        writeCompletionsByUuid.removeAll(keepingCapacity: false)

        for (_, handler) in notifyByUuid {
            handler.onError(disconnectedError)
        }
        notifyByUuid.removeAll(keepingCapacity: false)

        resetConnectionState()
    }

    private func resetConnectionState() {
        characteristicsByUuid.removeAll(keepingCapacity: false)
        pendingServicesCount = 0
        didReportConnected = false
    }

    private func mapDisconnectReason(error: Error?) -> DisconnectReason {
        guard let nsError = error as NSError? else {
            return .deviceDisconnected
        }

        if nsError.code == 6 {
            return .timeout
        }
        if nsError.code == 7 {
            return .deviceDisconnected
        }
        return .unknownError
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectCompletion?(.failure(error))
            connectCompletion = nil
            return
        }

        guard let services = peripheral.services else {
            connectCompletion?(.failure(AidlabError(message: "No services are available.")))
            connectCompletion = nil
            return
        }

        pendingServicesCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }

        if pendingServicesCount == 0, !didReportConnected {
            didReportConnected = true
            connectCompletion?(.success(()))
            connectCompletion = nil
        }
    }

    func peripheral(_: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            connectCompletion?(.failure(error))
            connectCompletion = nil
            return
        }

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                characteristicsByUuid[characteristic.uuid] = characteristic
            }
        }

        pendingServicesCount -= 1
        if pendingServicesCount == 0, !didReportConnected {
            didReportConnected = true
            connectCompletion?(.success(()))
            connectCompletion = nil
        }
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        if let handler = notifyByUuid.removeValue(forKey: characteristic.uuid) {
            handler.onError(error)
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if var completions = readCompletionsByUuid[characteristic.uuid], !completions.isEmpty {
                let completion = completions.removeFirst()
                readCompletionsByUuid[characteristic.uuid] = completions.isEmpty ? nil : completions
                completion(.failure(error))
                return
            }

            if let handler = notifyByUuid.removeValue(forKey: characteristic.uuid) {
                handler.onError(error)
            }
            return
        }

        guard let value = characteristic.value else { return }

        if var completions = readCompletionsByUuid[characteristic.uuid], !completions.isEmpty {
            let completion = completions.removeFirst()
            readCompletionsByUuid[characteristic.uuid] = completions.isEmpty ? nil : completions
            completion(.success(value))
            return
        }

        if let handler = notifyByUuid[characteristic.uuid] {
            handler.onData(value)
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard var completions = writeCompletionsByUuid[characteristic.uuid], !completions.isEmpty else {
            return
        }

        let completion = completions.removeFirst()
        writeCompletionsByUuid[characteristic.uuid] = completions.isEmpty ? nil : completions

        if let error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }

    func peripheral(_: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error != nil { return }
        rssi = RSSI
        onRSSIRead?(RSSI)
    }
}
