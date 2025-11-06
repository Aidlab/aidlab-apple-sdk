//
//  Created by Szymon Gęsicki on 29/05/2020.
//  Copyright © 2020-2023 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

/// Callbacks may arrive on a background thread. Dispatch to the appropriate queue if needed.
public protocol DeviceDelegate: AnyObject {
    func didReceiveECG(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveRespiration(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveBatteryLevel(_ device: Device, stateOfCharge: UInt8)

    func didReceiveSteps(_ device: Device, timestamp: UInt64, value: UInt64)

    func didReceiveSkinTemperature(_ device: Device, timestamp: UInt64, value: Float)

    func didReceiveAccelerometer(_ device: Device, timestamp: UInt64, ax: Float, ay: Float, az: Float)

    func didReceiveGyroscope(_ device: Device, timestamp: UInt64, qx: Float, qy: Float, qz: Float)

    func didReceiveMagnetometer(_ device: Device, timestamp: UInt64, mx: Float, my: Float, mz: Float)

    func didReceiveQuaternion(_ device: Device, timestamp: UInt64, qw: Float, qx: Float, qy: Float, qz: Float)

    func didReceiveOrientation(_ device: Device, timestamp: UInt64, roll: Float, pitch: Float, yaw: Float)

    func didReceiveEDA(_ device: Device, timestamp: UInt64, conductance: Float)

    func didReceiveGPS(_ device: Device, timestamp: UInt64, latitude: Double, longitude: Double, altitude: Double, speed: Float, heading: Float, hdop: Float)

    func didReceiveBodyPosition(_ device: Device, timestamp: UInt64, bodyPosition: BodyPosition)

    func didReceiveHeartRate(_ device: Device, timestamp: UInt64, heartRate: Int32)

    func didReceiveRr(_ device: Device, timestamp: UInt64, rr: Int32)

    func didReceiveRespirationRate(_ device: Device, timestamp: UInt64, value: UInt32)

    func didReceiveSoundVolume(_ device: Device, timestamp: UInt64, soundVolume: UInt16)

    func didDetect(_ device: Device, exercise: Exercise)

    func didDetect(_ device: Device, timestamp: UInt64, activity: ActivityType)

    func didDisconnect(_ device: Device, reason: DisconnectReason)

    func didConnect(_ device: Device)

    func didReceiveError(_ device: Device, error: Error)

    func didUpdateRSSI(_ device: Device, rssi: Int32)
    /**
     * Called when a significant change of wear state did occur. You can use
     * that information to make decisions when to start processing data, or
     * display short user guide how to wear Aidlab in your app.
     * @param  wearState    Current wear state.
     */
    func wearStateDidChange(_ device: Device, state: WearState)

    /// Called when a payload was received from a process (raw bytes).
    /// - Parameters:
    ///   - device: The Aidlab device instance
    ///   - process: The process name that sent the payload (e.g., "ping", "sync", "system")
    ///   - payload: Raw payload data as Data
    func didReceivePayload(_ device: Device, process: String, payload: Data)

    func didDetectUserEvent(_ device: Device, timestamp: UInt64)

    func didReceiveSignalQuality(_ device: Device, timestamp: UInt64, value: Int32)

    func syncStateDidChange(_ device: Device, state: SyncState)

    func didReceivePastECG(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastRespiration(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastSkinTemperature(_ device: Device, timestamp: UInt64, value: Float)

    func didReceivePastHeartRate(_ device: Device, timestamp: UInt64, heartRate: Int32)

    func didReceivePastRr(_ device: Device, timestamp: UInt64, rr: Int32)

    /// syncBytesPerSecond -> only available since firmware 3.7.69, in earlier versions it will be -1
    func didReceiveUnsynchronizedSize(_ device: Device, unsynchronizedSize: UInt32, syncBytesPerSecond: Float)

    func didReceivePastRespirationRate(_ device: Device, timestamp: UInt64, value: UInt32)

    func didReceivePastActivity(_ device: Device, timestamp: UInt64, activity: ActivityType)

    func didReceivePastSteps(_ device: Device, timestamp: UInt64, value: UInt64)

    func didReceivePastSoundVolume(_ device: Device, timestamp: UInt64, soundVolume: UInt16)

    func didReceivePastAccelerometer(_ device: Device, timestamp: UInt64, ax: Float, ay: Float, az: Float)

    func didReceivePastGyroscope(_ device: Device, timestamp: UInt64, qx: Float, qy: Float, qz: Float)

    func didReceivePastMagnetometer(_ device: Device, timestamp: UInt64, mx: Float, my: Float, mz: Float)

    func didReceivePastQuaternion(_ device: Device, timestamp: UInt64, qw: Float, qx: Float, qy: Float, qz: Float)

    func didReceivePastOrientation(_ device: Device, timestamp: UInt64, roll: Float, pitch: Float, yaw: Float)

    func didReceivePastEDA(_ device: Device, timestamp: UInt64, conductance: Float)

    func didReceivePastGPS(_ device: Device, timestamp: UInt64, latitude: Double, longitude: Double, altitude: Double, speed: Float, heading: Float, hdop: Float)

    func didReceivePastBodyPosition(_ device: Device, timestamp: UInt64, bodyPosition: BodyPosition)

    func didReceivePastPressure(_ device: Device, timestamp: UInt64, value: Int32)

    func didDetectPastUserEvent(_ device: Device, timestamp: UInt64)

    func didReceivePastSignalQuality(_ device: Device, timestamp: UInt64, value: UInt8)

    func pressureWearStateDidChange(_ device: Device, wearState: WearState)

    func didReceivePressure(_ device: Device, timestamp: UInt64, value: Int32)
}
