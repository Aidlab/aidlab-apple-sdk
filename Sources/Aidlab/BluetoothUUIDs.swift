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
var soundFeaturesCharacteristicUUID: CBUUID { makeUUID("54366E80-CF3A-11E1-9AB4-0002A5D5C51B") }

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

var dataTypesUUID: [DataType: CBUUID] {
    [
        DataType.activity: MotionService.activityUUID,
        DataType.steps: MotionService.stepsUUID,
        DataType.orientation: MotionService.orientationUUID,
        DataType.heartRate: HeartRateService.heartRateMeasurementCharacteristic,
        DataType.soundVolume: soundVolumeCharacteristicUUID,
        DataType.skinTemperature: temperatureCharacteristicUUID,
        DataType.motion: motionCharacteristicUUID,
        DataType.ecg: ecgCharacteristicUUID,
        DataType.respiration: respirationCharacteristicUUID,
    ]
}
