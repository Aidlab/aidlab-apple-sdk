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
    public var manufaturerName: String?
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

    public func readRSSI() {
        peripheral.readRSSI()
    }

    public func connect(delegate: DeviceDelegate) {
        deviceDelegate = delegate

        AidlabManager.centralManager?.connect(peripheral)
    }

    public func disconnect() {
        AidlabManager.centralManager?.cancelPeripheralConnection(peripheral)
    }

    public func startSynchronization() {
        send("sync start")
    }

    public func stopSynchronization() {
        send("sync stop")
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

    public func send(_ message: String) {
        guard let aidlabSDK else { return }

        let cStringMessage = strdup(message)
        let command: UnsafeMutablePointer<UInt8> = AidlabSDK_get_command(cStringMessage, aidlabSDK)
        free(cStringMessage)

        let size = command[3] | (command[4] << 8)

        _ = sendCommand(Array(UnsafeMutableBufferPointer(start: command, count: Int(size))))
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
            var realTime = dataTypes.map { UInt8($0.rawValue) }
            var sync = dataTypesToStore.map { UInt8($0.rawValue) }

            let command: UnsafeMutablePointer<UInt8> = AidlabSDK_get_collect_command(&realTime, Int32(dataTypes.count), &sync, Int32(dataTypesToStore.count), aidlabSDK)

            let size = command[3] | (command[4] << 8)
            _ = sendCommand(Array(UnsafeMutableBufferPointer(start: command, count: Int(size))))

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

    // -- internal -------------------------------------------------------------

    /// Array with CBUUID services for start notify
    let notifyServices: [CBUUID] = [userServiceUUID, MotionService.uuid, HeartRateService.uuid, HealthThermometerService.uuid, BatteryLevelService.uuid]

    /// Array with CBUUID services for read or write value
    let readWriteServices: [CBUUID] = [DeviceInformationService.uuid, CurrentTimeService.uuid]

    var discoveredCharacteristics: [CBCharacteristic] = []

    var aidlabSDK: UnsafeMutableRawPointer!
    var deviceDelegate: DeviceDelegate?
    internal(set) var bytes: Int = 0
    var cmdCharacteristic: CBCharacteristic?
    var heartRatePackageCharacteristic: CBCharacteristic?
    var maxCmdPackageLength: Int = 20

    /// Serial number, firmware, and hardware version are ready
    func didConnect() {
        if !checkCompatibility() {
            deviceDelegate?.didConnect(self)
            disconnect()
            return
        }

        createAidlabSDK()

        /// Users are notified about the connection after reading the firmware revision
        deviceDelegate?.didConnect(self)
    }

    func createAidlabSDK() {
        aidlabSDK = AidlabSDK_create()

        guard let firmwareRevision, let hardwareRevision else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Internal error"))
            return
        }

        var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
        AidlabSDK_set_firmware_revision(&fwVersion, Int32(fwVersion.count), aidlabSDK)
        if firmwareRevision.compare("3.6.62") != .orderedAscending {
            if let heartRatePackageCharacteristic {
                peripheral.setNotifyValue(false, for: heartRatePackageCharacteristic)
            }
        }

        var hwVersion: [UInt8] = Array(hardwareRevision.utf8)
        AidlabSDK_set_hardware_revision(&hwVersion, Int32(hwVersion.count), aidlabSDK)

        let context = Unmanaged.passUnretained(self).toOpaque()
        AidlabSDK_set_context(context, aidlabSDK)
        maxCmdPackageLength = 20
        AidlabSDK_set_mtu(UInt32(maxCmdPackageLength), aidlabSDK)
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
                                 didReceiveCommand,
                                 didReceiveMessage,
                                 didDetectUserEvent,
                                 didReceivePressure,
                                 pressureWearStateDidChange,
                                 didReceiveBodyPosition,
                                 didReceiveError,
                                 didReceiveSignalQuality,
                                 aidlabSDK)

        AidlabSDK_init_synchronization_callbacks(syncStateDidChange, didReceiveUnsynchronizedSize, didReceivePastECG, didReceivePastRespiration, didReceivePastSkinTemperature, didReceivePastHeartRate, didReceivePastRr, didReceivePastActivity, didReceivePastRespirationRate, didReceivePastSteps, didDetectPastUserEvent, didReceivePastSoundVolume, didReceivePastPressure, didReceivePastAccelerometer, didReceivePastGyroscope, didReceivePastQuaternion, didReceivePastOrientation, didReceivePastMagnetometer, didReceivePastBodyPosition, didReceivePastRr, didReceivePastSignalQuality, aidlabSDK)
    }

    func checkCompatibility() -> Bool {
        guard let version = firmwareRevision else { return true }
        let stringArray = version.split(separator: ".")
        let minor = Int(stringArray[1]) ?? 0
        return Config.supportedAidlabVersion >= minor ? true : false
    }

    func _setTime(_ characteristic: CBCharacteristic, currentTime: UInt32) {
        peripheral.writeValue(withUnsafeBytes(of: currentTime) { Data($0) }, for: characteristic, type: .withoutResponse)
    }

    // -- Private --------------------------------------------------------------

    private func sendCommand(_ command: [UInt8]) -> Bool {
        guard let cmdCharacteristic
        else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Command characteristic unavailable"))
            return false
        }

        var sendBuffer = [UInt8](repeating: 0, count: maxCmdPackageLength)
        var bufcount = 0
        let size = command.count

        /// Send data portion by portion (each portion == maxCmdPackageLength)
        for i in 0 ..< size {
            sendBuffer[i % maxCmdPackageLength] = command[i]
            bufcount += 1

            if bufcount == maxCmdPackageLength {
                bufcount = 0
                peripheral.writeValue(Data(sendBuffer), for: cmdCharacteristic, type: .withResponse)

                sendBuffer = Array(repeating: 0, count: maxCmdPackageLength)
            }
        }

        /// Send remaining data
        if bufcount != 0 {
            for i in bufcount ..< maxCmdPackageLength {
                sendBuffer[i] = 0
            }
            peripheral.writeValue(Data(sendBuffer), for: cmdCharacteristic, type: .withResponse)
        }

        return true
    }

    // -- AidlabSDK callback handlers ------------------------------------------

    private let didReceiveECG: callbackSamplesTime = { context, timestamp, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveECG(self_, timestamp: timestamp, values: Array(UnsafeBufferPointer(start: data, count: Int(size))))
    }

    private let didReceiveRespiration: callbackSamplesTime = { context, timestamp, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRespiration(self_, timestamp: timestamp, values: Array(UnsafeBufferPointer(start: data, count: Int(size))))
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

    private let didReceivePressure: callbackPressure = { context, timestamp, pressureValues, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        let pressureValues = Array(UnsafeBufferPointer(start: pressureValues, count: Int(size)))
        self_.deviceDelegate?.didReceivePressure(self_, timestamp: timestamp, values: pressureValues)
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

    private let didReceiveCommand: callbackReceivedCommand = { context in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveCommand(self_)
    }

    private let didReceiveMessage: callbackMessage = { context, process, message in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        if let cStringPointer_message = message {
            if let string_message = String(validatingUTF8: cStringPointer_message) {
                if let cStringPointer_process = process {
                    if let string_process = String(validatingUTF8: cStringPointer_process) {
                        self_.deviceDelegate?.didReceiveMessage(self_, process: string_process, message: string_message)
                    }
                }
            }
        }
    }

    private let didDetectUserEvent: callbackUserEvent = { context, timestamp in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectUserEvent(self_, timestamp: timestamp)
    }

    private let didReceiveSoundFeatures: callbackSoundFeatures = { _, _, _ in
        /// Experimental
    }

    private let didReceiveError: callbackError = { context, text in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        if let cStringPointer = text {
            if let string = String(validatingUTF8: cStringPointer) {
                self_.deviceDelegate?.didReceiveError(self_, error: AidlabError(message: string))
            } else {
                self_.deviceDelegate?.didReceiveError(self_, error: AidlabError(message: "Unknown error"))
            }
        }
    }

    private let didReceiveSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSignalQuality(timestamp, value: Int32(value))
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

    private let didReceivePastECG: callbackSamplesTime = { context, timestamp, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastECG(self_, timestamp: timestamp, values: Array(UnsafeBufferPointer(start: data, count: Int(size))))
    }

    private let didReceivePastRespiration: callbackSamplesTime = { context, timestamp, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRespiration(self_, timestamp: timestamp, values: Array(UnsafeBufferPointer(start: data, count: Int(size))))
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

    private let didReceivePastPressure: callbackPressure = { context, timestamp, values, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        let pressureValues = Array(UnsafeBufferPointer(start: values, count: Int(size)))
        self_.deviceDelegate?.didReceivePastPressure(self_, timestamp: timestamp, values: pressureValues)
    }

    private let didReceivePastSoundFeatures: callbackSoundFeatures = { _, _, _ in
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
