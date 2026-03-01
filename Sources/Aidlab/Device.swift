//
//  Created by J Domaszewicz on 10.11.2016.
//  Copyright © 2016-2024 Aidlab. All rights reserved.
//

import AidlabSDK
@preconcurrency import CoreBluetooth
import Foundation

public class Device: NSObject, @unchecked Sendable {
    public var name: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var serialNumber: String?
    public var manufacturerName: String?
    public var address: UUID
    public var rssi: NSNumber {
        get { transport.rssi }
        set { transport.rssi = newValue }
    }

    let transport: AidlabTransport
    private var activeNotificationUUIDs: Set<CBUUID> = []
    private var didHandleDisconnect = false

    /// Backwards-compatible access to the underlying CoreBluetooth peripheral, if applicable.
    public var peripheral: CBPeripheral? {
        (transport as? CoreBluetoothAidlabTransport)?.peripheral
    }

    public init(transport: AidlabTransport) {
        self.transport = transport
        address = transport.address
        name = transport.name
        super.init()

        if let coreBluetoothTransport = transport as? CoreBluetoothAidlabTransport {
            coreBluetoothTransport.onRSSIRead = { [weak self] rssi in
                guard let self else { return }
                deviceDelegate?.didUpdateRSSI(self, rssi: rssi.int32Value)
            }
        }
    }

    public convenience init(peripheral: CBPeripheral, rssi: NSNumber) {
        let defaultTransport =
            CoreBluetoothAidlabTransport(
                peripheral: peripheral,
                rssi: rssi,
                centralManagerProvider: { AidlabManager.centralManager }
            )
        self.init(transport: defaultTransport)
    }

    public convenience init(peripheral: CBPeripheral, rssi: NSNumber, centralManager: CBCentralManager) {
        let defaultTransport =
            CoreBluetoothAidlabTransport(
                peripheral: peripheral,
                rssi: rssi,
                centralManager: centralManager
            )
        self.init(transport: defaultTransport)
    }

    public func connect(delegate: DeviceDelegate) {
        deviceDelegate = delegate
        resetBleQueue()
        didHandleDisconnect = false
        stopAllNotifications()

        transport.onDisconnect = { [weak self] reason, error in
            guard let self else { return }
            if let error {
                deviceDelegate?.didReceiveError(self, error: error)
            }
            handleDisconnected(reason: reason)
        }

        transport.connect { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                onTransportConnected()
            case let .failure(error):
                deviceDelegate?.didReceiveError(self, error: error)
            }
        }
    }

    public func disconnect() {
        resetBleQueue()
        transport.disconnect()
    }

    public func collect(dataTypes: [DataType], dataTypesToStore: [DataType]) {
        guard aidlabSDK != nil else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API."))
            return
        }

        guard let firmwareRevision, let firmwareSemantic = SemVersion(firmwareRevision), let legacySemanticVersion = SemVersion("3.6.0") else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API."))
            return
        }

        if firmwareSemantic >= legacySemanticVersion {
            // Build flags from signal arrays (use bit flags)
            var liveFlags: UInt32 = 0
            var syncFlags: UInt32 = 0

            for signal in dataTypes {
                liveFlags |= 1 << signal.rawValue
            }

            for signal in dataTypesToStore {
                syncFlags |= 1 << signal.rawValue
            }

            // Check firmware version to determine collect format
            if let firmwareVersion3780 = SemVersion("3.7.80"), firmwareSemantic >= firmwareVersion3780 {
                // CollectSettingsString - newer firmware expects string format
                let liveHex = String(format: "%08X", liveFlags)
                let syncHex = String(format: "%08X", syncFlags)
                let collectCommand = "collect flags \(liveHex) \(syncHex)"
                send(commandBytes(collectCommand), processId: 0)
            } else {
                // Build binary command for older firmware
                let prefix = "collect on "
                var buffer = Array(prefix.utf8)

                // Add live flags (4 bytes, big-endian)
                buffer.append(UInt8((liveFlags >> 24) & 0xFF))
                buffer.append(UInt8((liveFlags >> 16) & 0xFF))
                buffer.append(UInt8((liveFlags >> 8) & 0xFF))
                buffer.append(UInt8((liveFlags >> 0) & 0xFF))

                // Add sync flags (4 bytes, big-endian)
                buffer.append(UInt8((syncFlags >> 24) & 0xFF))
                buffer.append(UInt8((syncFlags >> 16) & 0xFF))
                buffer.append(UInt8((syncFlags >> 8) & 0xFF))
                buffer.append(UInt8((syncFlags >> 0) & 0xFF))

                send(buffer, processId: 0)
            }

        } else { /// Legacy
            startLegacyCollection(dataTypes: dataTypes)
        }
    }

    public func readRSSI() {
        guard let peripheral else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "RSSI not available for this transport"))
            return
        }
        peripheral.readRSSI()
    }

    public func startSynchronization() {
        send(commandBytes("sync start"))
    }

    public func stopSynchronization() {
        send(commandBytes("sync stop"))
    }

    public func setTime(_ timestamp: UInt32) {
        let payload = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
        transport.writeCharacteristic(
            CurrentTimeService.currentTimeCharacteristic,
            data: payload,
            withResponse: true
        ) { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                deviceDelegate?.didReceiveError(self, error: error)
            }
        }
    }

    public func send(_ bytes: [UInt8], processId: Int = 0) {
        guard let aidlabSDK, !bytes.isEmpty else { return }
        var payload = bytes
        AidlabSDK_send(&payload, Int32(payload.count), Int32(processId), aidlabSDK)
    }

    // -- Internal -------------------------------------------------------------

    // Avoid implicitly unwrapped optional; use optional and guard when needed
    var aidlabSDK: UnsafeMutableRawPointer?
    var deviceDelegate: DeviceDelegate?

    var maxCmdPackageLength: Int = 20

    // BLE transport state (chunk queue handled on the main actor)
    var chunkQueue: [Data] = []
    var readyForNextChunk: Bool = true

    private func startNotify(
        uuid: CBUUID,
        required: Bool,
        onData: @escaping (Data) -> Void
    ) {
        activeNotificationUUIDs.insert(uuid)
        transport.startNotifications(
            uuid,
            onData: onData,
            onError: { [weak self] error in
                guard let self else { return }
                if required {
                    deviceDelegate?.didReceiveError(self, error: error)
                    transport.disconnect()
                }
            }
        )
    }

    private func stopAllNotifications() {
        for uuid in activeNotificationUUIDs {
            transport.stopNotifications(uuid)
        }
        activeNotificationUUIDs.removeAll(keepingCapacity: false)
    }

    func onTransportConnected() {
        readConnectionMetadata { [weak self] in
            self?.didConnect()
        }
    }

    func handleDisconnected(reason: DisconnectReason) {
        if didHandleDisconnect {
            return
        }
        didHandleDisconnect = true

        var resolvedReason = reason
        if !checkCompatibility() {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Unsupported SDK"))
            resolvedReason = .sdkOutdated
        }

        stopAllNotifications()
        resetBleQueue()

        if let aidlabSDK {
            AidlabSDK_set_log_callback(nil, nil, aidlabSDK)
            AidlabSDK_set_context(nil, aidlabSDK)
            AidlabSDK_destroy(aidlabSDK)
        }
        aidlabSDK = nil

        deviceDelegate?.didDisconnect(self, reason: resolvedReason)
        deviceDelegate = nil
        transport.onDisconnect = nil
    }

    private func readConnectionMetadata(completion: @escaping () -> Void) {
        func readUtf8(_ uuid: CBUUID, completion: @escaping (String?) -> Void) {
            transport.readCharacteristic(uuid) { result in
                switch result {
                case let .success(data):
                    let value = String(bytes: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\0", with: "") ?? ""
                    completion(value.isEmpty ? nil : value)
                case .failure:
                    completion(nil)
                }
            }
        }

        readUtf8(DeviceInformationService.manufacturerNameStringCharacteristic) { [weak self] value in
            guard let self else { return }
            manufacturerName = value
            readUtf8(DeviceInformationService.serialNumberStringCharacteristic) { [weak self] value in
                guard let self else { return }
                serialNumber = value
                readUtf8(DeviceInformationService.firmwareRevisionStringCharacteristic) { [weak self] value in
                    guard let self else { return }
                    firmwareRevision = value
                    readUtf8(DeviceInformationService.hardwareRevisionStringCharacteristic) { [weak self] value in
                        guard let self else { return }
                        hardwareRevision = value

                        guard serialNumber != nil, firmwareRevision != nil, hardwareRevision != nil else {
                            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Failed to read device metadata"))
                            transport.disconnect()
                            return
                        }

                        completion()
                    }
                }
            }
        }
    }

    /// Serial number, firmware, and hardware version are ready
    private func didConnect() {
        if !checkCompatibility() {
            deviceDelegate?.didConnect(self)
            disconnect()
            return
        }

        setTime(UInt32(Date().timeIntervalSince1970))

        createAidlabSDK()

        if supportsExtendedMtu() {
            let negotiated = transport.mtuSize
            maxCmdPackageLength = max(20, negotiated > 0 ? negotiated : 20)
        } else {
            maxCmdPackageLength = 20
        }
        startNotify(
            uuid: cmdCharacteristicUUID,
            required: true,
            onData: { [weak self] data in
                self?.processCommandChunk(data)
            }
        )
        drainChunkQueue()

        startNotify(
            uuid: BatteryLevelService.batteryLevelCharacteristic,
            required: false,
            onData: { [weak self] data in
                self?.processBatteryPacket(data)
            }
        )

        /// Users are notified about the connection after reading the firmware revision
        deviceDelegate?.didConnect(self)
    }

    func createAidlabSDK() {
        guard let firmwareRevision else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Missing firmware revision"))
            return
        }

        var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
        aidlabSDK = AidlabSDK_create(&fwVersion, Int32(fwVersion.count))
        resetBleQueue()

        guard let aidlabSDK else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Internal error"))
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AidlabSDK_set_context(context, aidlabSDK)
        AidlabSDK_set_log_callback(didReceiveLogMessage, context, aidlabSDK)

        AidlabSDK_set_ble_send_callback(bleSendCallback, aidlabSDK)
        AidlabSDK_set_ble_ready_callback(bleReadyCallback, aidlabSDK)

        AidlabSDK_init_callbacks(didReceiveECG,
                                 didReceiveRespiration,
                                 didReceiveSkinTemperature,
                                 didReceiveAccelerometer,
                                 didReceiveGyroscope,
                                 didReceiveMagnetometer,
                                 didReceiveBatteryLevel,
                                 didDetectActivity,
                                 didReceiveSteps,
                                 didReceiveOrientation,
                                 didReceiveQuaternion,
                                 didReceiveRespirationRate,
                                 wearStateDidChange,
                                 didReceiveHeartRate,
                                 didReceiveRr,
                                 didReceiveSoundVolume,
                                 didDetect,
                                 didDetectUserEvent,
                                 didReceivePressure,
                                 pressureWearStateDidChange,
                                 didReceiveBodyPosition,
                                 didReceiveSignalQuality,
                                 aidlabSDK)

        AidlabSDK_set_eda_callback(didReceiveEDA, aidlabSDK)
        AidlabSDK_set_gps_callback(didReceiveGPS, aidlabSDK)

        AidlabSDK_set_payload_callback(didReceivePayload, aidlabSDK)

        AidlabSDK_init_synchronization_callbacks(syncStateDidChange, didReceiveUnsynchronizedSize, didReceivePastECG, didReceivePastRespiration, didReceivePastSkinTemperature, didReceivePastHeartRate, didReceivePastRr, didReceivePastActivity, didReceivePastRespirationRate, didReceivePastSteps, didDetectPastUserEvent, didReceivePastSoundVolume, didReceivePastPressure, didReceivePastAccelerometer, didReceivePastGyroscope, didReceivePastQuaternion, didReceivePastOrientation, didReceivePastMagnetometer, didReceivePastBodyPosition, didReceivePastSignalQuality, aidlabSDK)
        AidlabSDK_set_past_eda_callback(didReceivePastEDA, aidlabSDK)
        AidlabSDK_set_past_gps_callback(didReceivePastGPS, aidlabSDK)
    }

    func checkCompatibility() -> Bool {
        guard let version = firmwareRevision else { return true }
        let stringArray = version.split(separator: ".")
        let minor = Int(stringArray[1]) ?? 0
        return Config.supportedAidlabVersion >= minor ? true : false
    }

    // -- Private --------------------------------------------------------------

    private func sendRawBleData(_ data: [UInt8]) {
        guard !data.isEmpty else {
            drainChunkQueue()
            return
        }

        let chunkSize = resolvedChunkSize()
        var offset = 0

        while offset < data.count {
            let endIndex = min(offset + chunkSize, data.count)
            let chunk = Data(data[offset ..< endIndex])
            chunkQueue.append(chunk)
            offset = endIndex
        }

        drainChunkQueue()
    }

    private func resolvedChunkSize() -> Int {
        guard supportsExtendedMtu() else {
            return 20
        }

        let negotiated = transport.mtuSize
        if negotiated > 0 {
            return min(maxCmdPackageLength, max(20, negotiated))
        }
        return 20
    }

    func resetBleQueue() {
        chunkQueue.removeAll(keepingCapacity: false)
        readyForNextChunk = true
    }

    private func supportsExtendedMtu() -> Bool {
        guard let firmwareRevision else { return false }
        let sanitized = firmwareRevision.split(separator: "-").first.map(String.init) ?? firmwareRevision
        guard let current = SemVersion(sanitized),
              let threshold = SemVersion("4.0.0")
        else { return false }
        return current >= threshold
    }

    private func commandBytes(_ command: String) -> [UInt8] {
        var bytes = Array(command.utf8)
        if bytes.isEmpty || bytes.last != 0 {
            bytes.append(0)
        }
        return bytes
    }

    private func startLegacyCollection(dataTypes: [DataType]) {
        var uuids: Set<CBUUID> = [batteryCharacteristicUUID]
        for dataType in dataTypes {
            if let uuid = dataTypesUUID[dataType] {
                uuids.insert(uuid)
            }
        }

        for uuid in uuids {
            startNotify(
                uuid: uuid,
                required: false,
                onData: { [weak self] data in
                    self?.processLegacyData(uuid: uuid, data: data)
                }
            )
        }
    }

    private func processCommandChunk(_ data: Data) {
        guard let aidlabSDK else { return }
        var scratchVal = [UInt8](data)
        AidlabSDK_process_ble_chunk(&scratchVal, Int32(scratchVal.count), aidlabSDK)
    }

    private func processBatteryPacket(_ data: Data) {
        guard aidlabSDK != nil else { return }
        var scratchVal = [UInt8](data)
        AidlabSDK_process_battery_package(&scratchVal, Int32(scratchVal.count), aidlabSDK)
    }

    private func processLegacyData(
        uuid: CBUUID,
        data: Data
    ) {
        guard aidlabSDK != nil else { return }
        var scratchVal = [UInt8](data)
        let count = Int32(scratchVal.count)

        switch uuid {
        case temperatureCharacteristicUUID:
            processTemperaturePackage(&scratchVal, count, aidlabSDK)
        case ecgCharacteristicUUID:
            processECGPackage(&scratchVal, count, aidlabSDK)
        case respirationCharacteristicUUID:
            processRespirationPackage(&scratchVal, count, aidlabSDK)
        case motionCharacteristicUUID:
            processMotionPackage(&scratchVal, count, aidlabSDK)
        case soundVolumeCharacteristicUUID:
            processSoundVolumePackage(&scratchVal, count, aidlabSDK)
        case MotionService.stepsUUID:
            processStepsPackage(&scratchVal, count, aidlabSDK)
        case MotionService.activityUUID:
            processActivityPackage(&scratchVal, count, aidlabSDK)
        case MotionService.orientationUUID:
            processOrientationPackage(&scratchVal, count, aidlabSDK)
        case HeartRateService.heartRateMeasurementCharacteristic:
            processHeartRatePackage(&scratchVal, count, aidlabSDK)
        case BatteryLevelService.batteryLevelCharacteristic, batteryCharacteristicUUID:
            AidlabSDK_process_battery_package(&scratchVal, count, aidlabSDK)
        default:
            break
        }
    }

    func drainChunkQueue() {
        guard readyForNextChunk else { return }
        guard !chunkQueue.isEmpty else { return }

        let chunk = chunkQueue.removeFirst()
        readyForNextChunk = false
        transport.writeCharacteristic(cmdCharacteristicUUID, data: chunk, withResponse: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                handleCommandWriteResult(error: nil)
            case let .failure(error):
                handleCommandWriteResult(error: error)
            }
        }
    }

    func handleCommandWriteResult(error: Error?) {
        if let error {
            resetBleQueue()
            deviceDelegate?.didReceiveError(self, error: error)
            return
        }

        readyForNextChunk = true
        drainChunkQueue()
    }

    // -- AidlabSDK callback handlers ------------------------------------------

    // BLE Communication callbacks
    private let bleSendCallback: callbackBLESend = { context, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        let dataArray = Array(UnsafeBufferPointer(start: data, count: Int(size)))
        self_.sendRawBleData(dataArray)
    }

    private let bleReadyCallback: callbackBLEReady = { context in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.readyForNextChunk = true
        self_.drainChunkQueue()
    }

    private let didReceiveECG: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveECG(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveRespiration: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRespiration(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveSkinTemperature: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSkinTemperature(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveAccelerometer: callbackAccelerometer = { context, timestamp, ax, ay, az in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveAccelerometer(self_, timestamp: timestamp, ax: ax, ay: ay, az: az)
    }

    private let didReceiveGyroscope: callbackGyroscope = { context, timestamp, gx, gy, gz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveGyroscope(self_, timestamp: timestamp, qx: gx, qy: gy, qz: gz)
    }

    private let didReceiveMagnetometer: callbackMagnetometer = { context, timestamp, mx, my, mz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveMagnetometer(self_, timestamp: timestamp, mx: mx, my: my, mz: mz)
    }

    private let didReceiveQuaternion: callbackQuaternion = { context, timestamp, qw, qx, qy, qz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveQuaternion(self_, timestamp: timestamp, qw: qw, qx: qx, qy: qy, qz: qz)
    }

    private let didReceiveOrientation: callbackOrientation = { context, timestamp, roll, pitch, yaw in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveOrientation(self_, timestamp: timestamp, roll: roll, pitch: pitch, yaw: yaw)
    }

    private let didReceiveEDA: callbackEda = { context, timestamp, conductance in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveEDA(self_, timestamp: timestamp, conductance: conductance)
    }

    private let didReceiveGPS: callbackGps = { context, timestamp, latitude, longitude, altitude, speed, heading, hdop in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveGPS(self_,
                                            timestamp: timestamp,
                                            latitude: Double(latitude),
                                            longitude: Double(longitude),
                                            altitude: Double(altitude),
                                            speed: speed,
                                            heading: heading,
                                            hdop: hdop)
    }

    private let didReceiveBodyPosition: callbackBodyPosition = { context, timestamp, bodyPosition in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveBodyPosition(self_, timestamp: timestamp, bodyPosition: BodyPosition(bodyPosition: bodyPosition))
    }

    private let didReceiveHeartRate: callbackHeartRate = { context, timestamp, heartRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveHeartRate(self_, timestamp: timestamp, heartRate: heartRate)
    }

    private let didReceiveRr: callbackRr = { context, timestamp, rr in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRr(self_, timestamp: timestamp, rr: rr)
    }

    private let didReceiveRespirationRate: callbackRespirationRate = { context, timestamp, respirationRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRespirationRate(self_, timestamp: timestamp, value: respirationRate)
    }

    private let wearStateDidChange: callbackWearState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.wearStateDidChange(self_, state: WearState(wearState: state))
    }

    private let didReceiveSoundVolume: callbackSoundVolume = { context, timestamp, soundVolume in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSoundVolume(self_, timestamp: timestamp, soundVolume: soundVolume)
    }

    private let didReceivePressure: callbackPressure = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePressure(self_, timestamp: timestamp, value: value)
    }

    private let pressureWearStateDidChange: callbackWearState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.pressureWearStateDidChange(self_, wearState: WearState(wearState: state))
    }

    private let didDetect: callback_function = { context, exercise in
        guard let context else { return }
        if exercise == AidlabSDK.none { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetect(self_, exercise: Exercise(exercise: exercise))
    }

    private let didDetectActivity: callbackActivity = { context, timestamp, activity in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetect(self_, timestamp: timestamp, activity: ActivityType(activityType: activity))
    }

    private let didReceivePayload: callbackPayload = { context, process, payload, payloadLength in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        let processString = process.map { String(cString: $0) } ?? "unknown"

        let rawPayload = if let payload, payloadLength > 0 {
            Data(bytes: payload, count: Int(payloadLength))
        } else {
            Data()
        }

        self_.deviceDelegate?.didReceivePayload(self_, process: processString, payload: rawPayload)
    }

    private let didDetectUserEvent: callbackUserEvent = { context, timestamp in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectUserEvent(self_, timestamp: timestamp)
    }

    private let didReceiveLogMessage: callbackLogMessage = { context, level, text in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        guard let cStringPointer = text,
              let string = String(validatingCString: cStringPointer)
        else { return }

        if level.rawValue == 3 { self_.deviceDelegate?.didReceiveError(self_, error: AidlabError(message: string))
        }
    }

    private let didReceiveSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSignalQuality(self_, timestamp: timestamp, value: Int32(value))
    }

    private let didReceiveBatteryLevel: callbackBatteryLevel = { context, stateOfCharge in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveBatteryLevel(self_, stateOfCharge: stateOfCharge)
    }

    private let didReceiveSteps: callbackSteps = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSteps(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastECG: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastECG(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastRespiration: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRespiration(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastSkinTemperature: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSkinTemperature(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastHeartRate: callbackHeartRate = { context, timestamp, heartRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastHeartRate(self_, timestamp: timestamp, heartRate: heartRate)
    }

    private let syncStateDidChange: callbackSyncState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.syncStateDidChange(self_, state: SyncState(syncState: state))
    }

    private let didReceiveUnsynchronizedSize: callbackUnsynchronizedSize = { context, unsynchronizedSize, syncBytesPerSecond in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveUnsynchronizedSize(self_, unsynchronizedSize: unsynchronizedSize, syncBytesPerSecond: syncBytesPerSecond)
    }

    private let didReceivePastRespirationRate: callbackRespirationRate = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRespirationRate(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastActivity: callbackActivity = { context, timestamp, activity in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastActivity(self_, timestamp: timestamp, activity: ActivityType(activityType: activity))
    }

    private let didReceivePastSteps: callbackSteps = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSteps(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastRr: callbackRr = { context, timestamp, rr in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRr(self_, timestamp: timestamp, rr: rr)
    }

    private let didReceivePastSoundVolume: callbackSoundVolume = { context, timestamp, soundVolume in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSoundVolume(self_, timestamp: timestamp, soundVolume: soundVolume)
    }

    private let didReceivePastPressure: callbackPressure = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastPressure(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastAccelerometer: callbackAccelerometer = { context, timestamp, ax, ay, az in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastAccelerometer(self_, timestamp: timestamp, ax: ax, ay: ay, az: az)
    }

    private let didReceivePastGyroscope: callbackGyroscope = { context, timestamp, gx, gy, gz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastGyroscope(self_, timestamp: timestamp, qx: gx, qy: gy, qz: gz)
    }

    private let didReceivePastQuaternion: callbackQuaternion = { context, timestamp, qw, qx, qy, qz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastQuaternion(self_, timestamp: timestamp, qw: qw, qx: qx, qy: qy, qz: qz)
    }

    private let didReceivePastOrientation: callbackOrientation = { context, timestamp, roll, pitch, yaw in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastOrientation(self_, timestamp: timestamp, roll: roll, pitch: pitch, yaw: yaw)
    }

    private let didReceivePastEDA: callbackEda = { context, timestamp, conductance in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastEDA(self_, timestamp: timestamp, conductance: conductance)
    }

    private let didReceivePastGPS: callbackGps = { context, timestamp, latitude, longitude, altitude, speed, heading, hdop in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastGPS(self_,
                                                timestamp: timestamp,
                                                latitude: Double(latitude),
                                                longitude: Double(longitude),
                                                altitude: Double(altitude),
                                                speed: speed,
                                                heading: heading,
                                                hdop: hdop)
    }

    private let didReceivePastMagnetometer: callbackMagnetometer = { context, timestamp, mx, my, mz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastMagnetometer(self_, timestamp: timestamp, mx: mx, my: my, mz: mz)
    }

    private let didReceivePastBodyPosition: callbackBodyPosition = { context, timestamp, bodyPosition in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastBodyPosition(self_, timestamp: timestamp, bodyPosition: BodyPosition(bodyPosition: bodyPosition))
    }

    private let didDetectPastUserEvent: callbackUserEvent = { context, timestamp in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectPastUserEvent(self_, timestamp: timestamp)
    }

    private let didReceivePastSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSignalQuality(self_, timestamp: timestamp, value: UInt8(value))
    }
}

struct SemVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ version: String) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        major = parts[0]
        minor = parts[1]
        patch = parts[2]
    }

    static func < (lhs: SemVersion, rhs: SemVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }

    static func == (lhs: SemVersion, rhs: SemVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}
