//
//  Created by Jakub Domaszewicz on 21/12/2023.
//

import Foundation
import CoreBluetooth

internal let signalsUUID: [DataType: [CBUUID]] = [
    DataType.battery: [batteryCharacteristicUUID, BatteryLevelService.batteryLevelCharacteristic],
    DataType.activity: [MotionService.activityUUID],
    DataType.steps: [MotionService.stepsUUID],
    DataType.orientation: [MotionService.orientationUUID],
    DataType.heartRate: [HeartRateService.heartRateMeasurementCharacteristic],
    DataType.soundVolume: [soundVolumeCharacteristicUUID],
    DataType.skinTemperature: [temperatureCharacteristicUUID],
    DataType.motion: [motionCharacteristicUUID],
    DataType.ecg: [ecgCharacteristicUUID],
    DataType.respiration: [respirationCharacteristicUUID]]

internal let userServiceUUID = CBUUID(string: "44366E80-CF3A-11E1-9AB4-0002A5D5C51B")

internal let temperatureCharacteristicUUID = CBUUID(string: "45366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let ecgCharacteristicUUID = CBUUID(string: "46366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let batteryCharacteristicUUID = CBUUID(string: "47366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let respirationCharacteristicUUID = CBUUID(string: "48366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let motionCharacteristicUUID = CBUUID(string: "49366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let cmdCharacteristicUUID = CBUUID(string: "51366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let soundVolumeCharacteristicUUID = CBUUID(string: "52366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let nasalCannulaCharacteristicUUID = CBUUID(string: "53366E80-CF3A-11E1-9AB4-0002A5D5C51B")
internal let soundFeaturesCharacteristicUUID = CBUUID(string: "54366E80-CF3A-11E1-9AB4-0002A5D5C51B")

internal enum MotionService {

    static let uuid = CBUUID(string: "60366E80-CF3A-11E1-9AB4-0002A5D5C51B")
    static let activityUUID = CBUUID(string: "61366E80-CF3A-11E1-9AB4-0002A5D5C51B")
    static let stepsUUID = CBUUID(string: "62366E80-CF3A-11E1-9AB4-0002A5D5C51B")
    static let orientationUUID = CBUUID(string: "63366E80-CF3A-11E1-9AB4-0002A5D5C51B")
}

internal enum DeviceInformationService {

    static let uuid = CBUUID(string: "180A")
    static let manufacturerNameStringCharacteristic = CBUUID(string: "2A29")
    static let serialNumberStringCharacteristic = CBUUID(string: "2A25")
    static let firmwareRevisionStringCharacteristic = CBUUID(string: "2A26")
    static let hardwareRevisionStringCharacteristic = CBUUID(string: "2A27")
}

internal enum HeartRateService {

    static let uuid = CBUUID(string: "180D")
    static let heartRateMeasurementCharacteristic = CBUUID(string: "2A37")
}

internal enum HealthThermometerService {

    static let uuid = CBUUID(string: "1809")
    static let temperatureMeasurementCharacteristic = CBUUID(string: "2A1C")
}

internal enum CurrentTimeService {

    static let uuid = CBUUID(string: "1805")
    static let currentTimeCharacteristic = CBUUID(string: "2A2B")
}

internal enum BatteryLevelService {

    static let uuid = CBUUID(string: "180F")
    static let batteryLevelCharacteristic = CBUUID(string: "2A19")
}
