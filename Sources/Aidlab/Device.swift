//
//  Created by J Domaszewicz on 10.11.2016.
//  Copyright © 2016-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import CoreBluetooth
import Foundation

public class Device: NSObject {
    public var name: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var serialNumber: String?
    public var manufacturerName: String?
    public var address: UUID
    public var rssi: NSNumber

    public var peripheral: CBPeripheral

    init(peripheral: CBPeripheral, rssi: NSNumber) {
        self.peripheral = peripheral
        address = peripheral.identifier
        name = peripheral.name
        self.rssi = rssi
        super.init()
        peripheral.delegate = self
    }

    public func connect(delegate: DeviceDelegate) {
        deviceDelegate = delegate

        AidlabManager.centralManager?.connect(peripheral)
    }

    public func disconnect() {
        resetBleQueue()
        AidlabManager.centralManager?.cancelPeripheralConnection(peripheral)
    }

    public func collect(dataTypes: [DataType], dataTypesToStore: [DataType]) {
        guard let aidlabSDK else {
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
                send(collectCommand, processId: 0)
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

                var dataArray = buffer
                AidlabSDK_send(&dataArray, Int32(dataArray.count), 0, aidlabSDK)
            }

            if let characteristic = discoveredCharacteristics.first(where: { $0.uuid == BatteryLevelService.batteryLevelCharacteristic }) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

        } else { /// Legacy
            if let characteristic = discoveredCharacteristics.first(where: { $0.uuid == batteryCharacteristicUUID }) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            for dataType in dataTypes {
                if let characteristic = dataTypesUUID[dataType] {
                    if let characteristic = discoveredCharacteristics.first(where: { $0.uuid == characteristic }) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }
        }
    }

    public func readRSSI() {
        peripheral.readRSSI()
    }

    public func startSynchronization() {
        send("sync start")
    }

    public func stopSynchronization() {
        send("sync stop")
    }

    public func setTime(_ timestamp: UInt32) {
        guard let currentTimeCharacteristic = discoveredCharacteristics.first(where: { $0.uuid == CurrentTimeService.currentTimeCharacteristic })
        else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Current time characteristic unavailable"))
            return
        }

        let payload = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
        peripheral.writeValue(payload, for: currentTimeCharacteristic, type: .withResponse)
    }

    public func setECGFiltrationMethod(_ ecgFiltrationMethod: ECGFiltrationMethod) {
        guard let aidlabSDK else { return }

        switch ecgFiltrationMethod {
        case .normal:
            AidlabSDK_set_aggressive_ecg_filtration(false, aidlabSDK)
        case .aggressive:
            AidlabSDK_set_aggressive_ecg_filtration(true, aidlabSDK)
        }
    }

    public func send(_ message: String, processId: Int = 0) {
        guard let aidlabSDK else { return }

        let messageData = message.utf8.map { UInt8($0) }
        var dataArray = messageData

        AidlabSDK_send(&dataArray, Int32(dataArray.count), Int32(processId), aidlabSDK)
    }

    // -- Internal -------------------------------------------------------------

    /// Array with CBUUID services for start notify
    let notifyServices: [CBUUID] = [userServiceUUID, MotionService.uuid, HeartRateService.uuid, HealthThermometerService.uuid, BatteryLevelService.uuid]

    /// Array with CBUUID services for read or write value
    let readWriteServices: [CBUUID] = [DeviceInformationService.uuid, CurrentTimeService.uuid]

    // Avoid implicitly unwrapped optional; use optional and guard when needed
    var aidlabSDK: UnsafeMutableRawPointer?
    var deviceDelegate: DeviceDelegate?

    var discoveredCharacteristics: [CBCharacteristic] = []

    var maxCmdPackageLength: Int = 20

    // BLE transport state (chunk queue handled on the main actor)
    var chunkQueue: [Data] = []
    var readyForNextChunk: Bool = true

    /// Serial number, firmware, and hardware version are ready
    func didConnect() {
        if !checkCompatibility() {
            deviceDelegate?.didConnect(self)
            disconnect()
            return
        }

        createAidlabSDK()

        if supportsExtendedMtu() {
            let negotiated = peripheral.maximumWriteValueLength(for: .withResponse)
            let attSafe = negotiated > 3 ? negotiated - 3 : negotiated
            maxCmdPackageLength = max(20, attSafe > 0 ? attSafe : 20)
        } else {
            maxCmdPackageLength = 20
        }
        setTime(UInt32(Date().timeIntervalSince1970))

        /// Users are notified about the connection after reading the firmware revision
        deviceDelegate?.didConnect(self)
    }

    func createAidlabSDK() {
        aidlabSDK = AidlabSDK_create()
        resetBleQueue()

        guard let firmwareRevision, let hardwareRevision else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Internal error"))
            return
        }

        guard let aidlabSDK else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Internal error"))
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AidlabSDK_set_context(context, aidlabSDK)
        AidlabSDK_set_log_callback(didReceiveLogMessage, context, aidlabSDK)

        var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
        AidlabSDK_set_firmware_revision(&fwVersion, Int32(fwVersion.count), aidlabSDK)

        var hwVersion: [UInt8] = Array(hardwareRevision.utf8)
        AidlabSDK_set_hardware_revision(&hwVersion, Int32(hwVersion.count), aidlabSDK)

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

        let negotiated = peripheral.maximumWriteValueLength(for: .withResponse)
        let attSafe = negotiated > 3 ? negotiated - 3 : negotiated
        if attSafe > 0 {
            return min(maxCmdPackageLength, max(20, attSafe))
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

    func drainChunkQueue() {
        guard readyForNextChunk else { return }
        guard !chunkQueue.isEmpty else { return }

        // Command characteristic discovery may lag behind queue population; wait until it's ready.
        guard let cmdCharacteristic = discoveredCharacteristics.first(where: { $0.uuid == cmdCharacteristicUUID }) else { return }

        let chunk = chunkQueue.removeFirst()
        readyForNextChunk = false
        peripheral.writeValue(chunk, for: cmdCharacteristic, type: .withResponse)
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

    private let didReceiveSoundFeatures: callbackSoundFeatures = { _, _, _, _ in
        /// Experimental
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

    private let didReceivePastSoundFeatures: callbackSoundFeatures = { _, _, _, _ in
        /// Experimental
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
