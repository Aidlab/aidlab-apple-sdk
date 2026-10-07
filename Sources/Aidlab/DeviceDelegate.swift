//
//  Created by Szymon Gęsicki on 29/05/2020.
//  Copyright © 2020-2023 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

/// Callbacks arrive on the main queue.
public protocol DeviceDelegate: AnyObject {
    func didReceiveECG(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveRespiration(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveBatteryLevel(_ device: Device, stateOfCharge: UInt8)

    func didReceiveSteps(_ device: Device, timestamp: UInt64, value: UInt64)

    func didReceiveSkinTemperature(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveAccelerometer(_ device: Device, timestamp: UInt64, ax: Float, ay: Float, az: Float)

    func didReceiveGyroscope(_ device: Device, timestamp: UInt64, gx: Float, gy: Float, gz: Float)

    func didReceiveMagnetometer(_ device: Device, timestamp: UInt64, mx: Float, my: Float, mz: Float)

    func didReceiveQuaternion(_ device: Device, timestamp: UInt64, qw: Float, qx: Float, qy: Float, qz: Float)

    func didReceiveOrientation(_ device: Device, timestamp: UInt64, roll: Float, pitch: Float, yaw: Float)

    func didReceiveEDA(_ device: Device, timestamp: UInt64, conductance: Float)

    /// - Parameters:
    ///   - speed: Speed in meters per second (m/s), compatible with CoreLocation.
    func didReceiveGPS(_ device: Device, timestamp: UInt64, latitude: Double, longitude: Double, altitude: Double, speed: Float, heading: Float, hdop: Float)

    func didReceiveBodyPosition(_ device: Device, timestamp: UInt64, bodyPosition: BodyPosition)

    func didReceiveHeartRate(_ device: Device, timestamp: UInt64, heartRate: Int32)

    func didReceiveRr(_ device: Device, timestamp: UInt64, rr: Int32)

    func didReceiveRespirationRate(_ device: Device, timestamp: UInt64, value: UInt32)

    func didReceiveSoundVolume(_ device: Device, timestamp: UInt64, soundVolume: UInt16)

    func didDisconnect(_ device: Device, reason: DisconnectReason)

    func didConnect(_ device: Device)

    func didReceiveError(_ device: Device, error: AidlabError)

    func didUpdateRSSI(_ device: Device, rssi: Int32)

    /// Called with wear-state changes, user events, exercises, activities and on-device ECG and sleep analysis, live
    /// and from synchronization. Later SDK versions may add event types, so ignore the types you do not handle.
    func didReceiveEvent(_ device: Device, event: any DeviceEvent)

    /// Called with each payload chunk received from a process (raw bytes).
    /// - Parameters:
    ///   - device: The Aidlab device instance
    ///   - pid: Runtime process ID; 0 for system output or protocols without process IDs
    ///   - payload: Raw payload data as Data
    ///   - options: Process-specific metadata received from the device
    func didReceivePayload(_ device: Device, pid: UInt16, payload: Data, options: UInt64)

    /// Called with stderr emitted by a device process. Aidlab 1 does not emit this callback.
    func didReceiveProcessError(_ device: Device, pid: UInt16, payload: Data, options: UInt64)

    /// Called after the device reports that a runtime process has terminated.
    func processDidTerminate(_ device: Device, pid: UInt16)

    func didReceiveSignalQuality(_ device: Device, timestamp: UInt64, value: UInt8)

    func syncStateDidChange(_ device: Device, state: SyncState)

    func didReceivePastECG(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastRespiration(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastSkinTemperature(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastHeartRate(_ device: Device, timestamp: UInt64, heartRate: Int32)

    func didReceivePastRr(_ device: Device, timestamp: UInt64, rr: Int32)

    /// syncBytesPerSecond -> only available since firmware 3.7.69, in earlier versions it will be -1
    func didReceiveUnsynchronizedSize(_ device: Device, unsynchronizedSize: UInt32, syncBytesPerSecond: Float)

    func didReceivePastRespirationRate(_ device: Device, timestamp: UInt64, value: UInt32)

    func didReceivePastSteps(_ device: Device, timestamp: UInt64, value: UInt64)

    func didReceivePastSoundVolume(_ device: Device, timestamp: UInt64, soundVolume: UInt16)

    func didReceivePastAccelerometer(_ device: Device, timestamp: UInt64, ax: Float, ay: Float, az: Float)

    func didReceivePastGyroscope(_ device: Device, timestamp: UInt64, gx: Float, gy: Float, gz: Float)

    func didReceivePastMagnetometer(_ device: Device, timestamp: UInt64, mx: Float, my: Float, mz: Float)

    func didReceivePastQuaternion(_ device: Device, timestamp: UInt64, qw: Float, qx: Float, qy: Float, qz: Float)

    func didReceivePastOrientation(_ device: Device, timestamp: UInt64, roll: Float, pitch: Float, yaw: Float)

    func didReceivePastEDA(_ device: Device, timestamp: UInt64, conductance: Float)

    /// - Parameters:
    ///   - speed: Speed in meters per second (m/s), compatible with CoreLocation.
    func didReceivePastGPS(_ device: Device, timestamp: UInt64, latitude: Double, longitude: Double, altitude: Double, speed: Float, heading: Float, hdop: Float)

    func didReceivePastBodyPosition(_ device: Device, timestamp: UInt64, bodyPosition: BodyPosition)

    func didReceivePastPressure(_ device: Device, timestamp: UInt64, value: Int32)

    func didReceivePastSignalQuality(_ device: Device, timestamp: UInt64, value: UInt8)

    func didReceivePressure(_ device: Device, timestamp: UInt64, value: Int32)
}

// Every callback except didConnect, didDisconnect and didReceiveError is optional.
public extension DeviceDelegate {
    func didReceiveECG(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveRespiration(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveBatteryLevel(_: Device, stateOfCharge _: UInt8) {}
    func didReceiveSteps(_: Device, timestamp _: UInt64, value _: UInt64) {}
    func didReceiveSkinTemperature(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveAccelerometer(_: Device, timestamp _: UInt64, ax _: Float, ay _: Float, az _: Float) {}
    func didReceiveGyroscope(_: Device, timestamp _: UInt64, gx _: Float, gy _: Float, gz _: Float) {}
    func didReceiveMagnetometer(_: Device, timestamp _: UInt64, mx _: Float, my _: Float, mz _: Float) {}
    func didReceiveQuaternion(_: Device, timestamp _: UInt64, qw _: Float, qx _: Float, qy _: Float, qz _: Float) {}
    func didReceiveOrientation(_: Device, timestamp _: UInt64, roll _: Float, pitch _: Float, yaw _: Float) {}
    func didReceiveEDA(_: Device, timestamp _: UInt64, conductance _: Float) {}
    func didReceiveGPS(_: Device, timestamp _: UInt64, latitude _: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) {}
    func didReceiveBodyPosition(_: Device, timestamp _: UInt64, bodyPosition _: BodyPosition) {}
    func didReceiveHeartRate(_: Device, timestamp _: UInt64, heartRate _: Int32) {}
    func didReceiveRr(_: Device, timestamp _: UInt64, rr _: Int32) {}
    func didReceiveRespirationRate(_: Device, timestamp _: UInt64, value _: UInt32) {}
    func didReceiveSoundVolume(_: Device, timestamp _: UInt64, soundVolume _: UInt16) {}
    func didUpdateRSSI(_: Device, rssi _: Int32) {}
    func didReceiveEvent(_: Device, event _: any DeviceEvent) {}
    func didReceivePayload(_: Device, pid _: UInt16, payload _: Data, options _: UInt64) {}
    func didReceiveProcessError(_: Device, pid _: UInt16, payload _: Data, options _: UInt64) {}
    func processDidTerminate(_: Device, pid _: UInt16) {}
    func didReceiveSignalQuality(_: Device, timestamp _: UInt64, value _: UInt8) {}
    func syncStateDidChange(_: Device, state _: SyncState) {}
    func didReceivePastECG(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastRespiration(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastSkinTemperature(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastHeartRate(_: Device, timestamp _: UInt64, heartRate _: Int32) {}
    func didReceivePastRr(_: Device, timestamp _: UInt64, rr _: Int32) {}
    func didReceiveUnsynchronizedSize(_: Device, unsynchronizedSize _: UInt32, syncBytesPerSecond _: Float) {}
    func didReceivePastRespirationRate(_: Device, timestamp _: UInt64, value _: UInt32) {}
    func didReceivePastSteps(_: Device, timestamp _: UInt64, value _: UInt64) {}
    func didReceivePastSoundVolume(_: Device, timestamp _: UInt64, soundVolume _: UInt16) {}
    func didReceivePastAccelerometer(_: Device, timestamp _: UInt64, ax _: Float, ay _: Float, az _: Float) {}
    func didReceivePastGyroscope(_: Device, timestamp _: UInt64, gx _: Float, gy _: Float, gz _: Float) {}
    func didReceivePastMagnetometer(_: Device, timestamp _: UInt64, mx _: Float, my _: Float, mz _: Float) {}
    func didReceivePastQuaternion(_: Device, timestamp _: UInt64, qw _: Float, qx _: Float, qy _: Float, qz _: Float) {}
    func didReceivePastOrientation(_: Device, timestamp _: UInt64, roll _: Float, pitch _: Float, yaw _: Float) {}
    func didReceivePastEDA(_: Device, timestamp _: UInt64, conductance _: Float) {}
    func didReceivePastGPS(_: Device, timestamp _: UInt64, latitude _: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) {}
    func didReceivePastBodyPosition(_: Device, timestamp _: UInt64, bodyPosition _: BodyPosition) {}
    func didReceivePastPressure(_: Device, timestamp _: UInt64, value _: Int32) {}
    func didReceivePastSignalQuality(_: Device, timestamp _: UInt64, value _: UInt8) {}
    func didReceivePressure(_: Device, timestamp _: UInt64, value _: Int32) {}
}
