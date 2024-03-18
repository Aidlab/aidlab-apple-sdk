//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import CoreBluetooth
import Foundation

extension Device: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            deviceDelegate?.didReceiveError(self, error: error)
            return
        }

        guard let serviceCharacteristics = service.characteristics else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Characteristic is nil"))
            return
        }

        for characteristic in serviceCharacteristics {
            discoveredCharacteristics.append(characteristic)
        }

        if service.uuid == userServiceUUID {
            for characteristic in serviceCharacteristics where characteristic.uuid == cmdCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

        } else if service.uuid == DeviceInformationService.uuid {
            /// We assume that all of characteristics are readable
            for characteristic in serviceCharacteristics {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    public func peripheral(_: CBPeripheral, didUpdateNotificationStateFor _: CBCharacteristic, error: Error?) {
        if let error {
            deviceDelegate?.didReceiveError(self, error: error)
            return
        }
    }

    public func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            deviceDelegate?.didReceiveError(self, error: error)
            return
        }

        guard let value = characteristic.value else { return }

        /// Device Information Characteristics

        if characteristic.uuid == DeviceInformationService.manufacturerNameStringCharacteristic {
            manufacturerName = String(bytes: value, encoding: String.Encoding.utf8)
        } else if characteristic.uuid == DeviceInformationService.serialNumberStringCharacteristic {
            if serialNumber != nil { return }

            serialNumber = String(bytes: value, encoding: String.Encoding.utf8)

            if serialNumber != nil, firmwareRevision != nil, hardwareRevision != nil {
                didConnect()
            }

        } else if characteristic.uuid == DeviceInformationService.firmwareRevisionStringCharacteristic {
            /// We don't want to read revision firmware twice
            if firmwareRevision != nil { return }

            firmwareRevision = String(bytes: value, encoding: String.Encoding.utf8)

            if serialNumber != nil, firmwareRevision != nil, hardwareRevision != nil {
                didConnect()
            }

        } else if characteristic.uuid == DeviceInformationService.hardwareRevisionStringCharacteristic {
            if hardwareRevision != nil { return }
            hardwareRevision = String(bytes: value, encoding: String.Encoding.utf8)

            if serialNumber != nil, firmwareRevision != nil, hardwareRevision != nil {
                didConnect()
            }
        }
        /// User Service Characteristics

        else if characteristic.uuid == temperatureCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processTemperaturePackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == ecgCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processECGPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == respirationCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processRespirationPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == batteryCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            AidlabSDK_process_battery_package(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == motionCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processMotionPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == cmdCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            bytes += value.count

            AidlabSDK_process_command(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == soundVolumeCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processSoundVolumePackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == nasalCannulaCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processNasalCannulaPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == soundFeaturesCharacteristicUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)
            processSoundFeaturesPackage(&scratchVal, Int32(value.count), aidlabSDK)
        }

        /// Motion Service Characteristics

        else if characteristic.uuid == MotionService.stepsUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processStepsPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == MotionService.activityUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processActivityPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == MotionService.orientationUUID {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processOrientationPackage(&scratchVal, Int32(value.count), aidlabSDK)
        }

        /// Heart Rate Service Characteristics

        else if characteristic.uuid == HeartRateService.heartRateMeasurementCharacteristic {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processHeartRatePackage(&scratchVal, Int32(value.count), aidlabSDK)
        }

        /// Health Thermometer Service Characteristics

        else if characteristic.uuid == HealthThermometerService.temperatureMeasurementCharacteristic {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processHealthThermometerPackage(&scratchVal, Int32(value.count), aidlabSDK)
        }

        /// Battery Level Service Characteristics

        else if characteristic.uuid == BatteryLevelService.batteryLevelCharacteristic {
            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)
            AidlabSDK_process_battery_package(&scratchVal, Int32(value.count), aidlabSDK)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "No services are available. \(error?.localizedDescription ?? "")"))
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error_ = error {
            deviceDelegate?.didReceiveError(self, error: error_)
            return
        }

        deviceDelegate?.didUpdateRSSI(self, rssi: RSSI.int32Value)
    }
}
