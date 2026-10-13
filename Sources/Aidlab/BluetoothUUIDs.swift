//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import CoreBluetooth
import Foundation

private func makeUUID(_ string: String) -> CBUUID {
    CBUUID(string: string)
}

var userServiceUUID: CBUUID { makeUUID("44366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var cmdCharacteristicUUID: CBUUID { makeUUID("51366E80-CF3A-11E1-9AB4-0002A5D5C51B") }

enum DeviceInformationService {
    static var uuid: CBUUID { makeUUID("180A") }
    static var manufacturerNameStringCharacteristic: CBUUID { makeUUID("2A29") }
    static var serialNumberStringCharacteristic: CBUUID { makeUUID("2A25") }
    static var firmwareRevisionStringCharacteristic: CBUUID { makeUUID("2A26") }
    static var hardwareRevisionStringCharacteristic: CBUUID { makeUUID("2A27") }
}

enum CurrentTimeService {
    static var uuid: CBUUID { makeUUID("1805") }
    static var currentTimeCharacteristic: CBUUID { makeUUID("2A2B") }
}

enum BatteryLevelService {
    static var uuid: CBUUID { makeUUID("180F") }
    static var batteryLevelCharacteristic: CBUUID { makeUUID("2A19") }
}

/// Legacy services and characteristics
var temperatureCharacteristicUUID: CBUUID { makeUUID("45366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var ecgCharacteristicUUID: CBUUID { makeUUID("46366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var batteryCharacteristicUUID: CBUUID { makeUUID("47366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var respirationCharacteristicUUID: CBUUID { makeUUID("48366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var motionCharacteristicUUID: CBUUID { makeUUID("49366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var soundVolumeCharacteristicUUID: CBUUID { makeUUID("52366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
var nasalCannulaCharacteristicUUID: CBUUID { makeUUID("53366E80-CF3A-11E1-9AB4-0002A5D5C51B") }

enum MotionService {
    static var uuid: CBUUID { makeUUID("60366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
    static var activityUUID: CBUUID { makeUUID("61366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
    static var stepsUUID: CBUUID { makeUUID("62366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
    static var orientationUUID: CBUUID { makeUUID("63366E80-CF3A-11E1-9AB4-0002A5D5C51B") }
}

enum HeartRateService {
    static var uuid: CBUUID { makeUUID("180D") }
    static var heartRateMeasurementCharacteristic: CBUUID { makeUUID("2A37") }
}

enum HealthThermometerService {
    static var uuid: CBUUID { makeUUID("1809") }
    static var temperatureMeasurementCharacteristic: CBUUID { makeUUID("2A1C") }
}

var dataTypesUUID: [Int: CBUUID] {
    [
        Device.activityData: MotionService.activityUUID,
        DataType.steps.rawValue: MotionService.stepsUUID,
        DataType.orientation.rawValue: MotionService.orientationUUID,
        DataType.bodyPosition.rawValue: MotionService.orientationUUID,
        DataType.heartRate.rawValue: HeartRateService.heartRateMeasurementCharacteristic,
        DataType.rr.rawValue: HeartRateService.heartRateMeasurementCharacteristic,
        DataType.soundVolume.rawValue: soundVolumeCharacteristicUUID,
        DataType.pressure.rawValue: nasalCannulaCharacteristicUUID,
        DataType.skinTemperature.rawValue: temperatureCharacteristicUUID,
        DataType.motion.rawValue: motionCharacteristicUUID,
        DataType.ecg.rawValue: ecgCharacteristicUUID,
        DataType.respiration.rawValue: respirationCharacteristicUUID,
        DataType.respirationRate.rawValue: respirationCharacteristicUUID,
    ]
}
