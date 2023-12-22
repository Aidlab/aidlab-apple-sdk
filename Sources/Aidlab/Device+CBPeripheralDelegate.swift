//
//  Created by Jakub Domaszewicz on 21/12/2023.
//

import Foundation
import CoreBluetooth
import AidlabSDK

extension Device: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {

        if let error = error {
            self.deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didDiscoverCharacteristicsFor \(error.localizedDescription)"))
            return
        }

        guard let serviceCharacteristics = service.characteristics else {
            self.deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didDiscoverCharacteristicsFor service.characteristics is nil"))
            return
        }

        if service.uuid == userServiceUUID && !alreadySubscribed.contains(userServiceUUID) {

            for characteristic in serviceCharacteristics {
                /// We assume that all of characteristics are notifiable
                if characteristicsToSubscribe.contains(characteristic.uuid) {
                    peripheral.setNotifyValue(true, for: characteristic)

                    if characteristic.uuid == cmdCharacteristicUUID {
                        self.cmdCharacteristic = characteristic
                    }
                }
            }

        } else if service.uuid == DeviceInformationService.uuid && !alreadySubscribed.contains(DeviceInformationService.uuid) {

            /// We assume that all of characteristics are readable
            for characteristic in serviceCharacteristics {
                peripheral.readValue(for: characteristic)
            }
        } else if service.uuid == MotionService.uuid && !alreadySubscribed.contains(MotionService.uuid) {

            /// We assume that all of characteristics are notifiable
            for characteristic in serviceCharacteristics {
                if characteristicsToSubscribe.contains(characteristic.uuid) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        } else if service.uuid == HeartRateService.uuid && !alreadySubscribed.contains(HeartRateService.uuid) {

            /// We assume that all of characteristics are notifiable
            for characteristic in serviceCharacteristics {
                if characteristicsToSubscribe.contains(characteristic.uuid) {
                    heartRatePackageCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        } else if service.uuid == HealthThermometerService.uuid && !alreadySubscribed.contains(HealthThermometerService.uuid) {

            /// We assume that all of characteristics are notifiable
            for characteristic in serviceCharacteristics {
                if characteristicsToSubscribe.contains(characteristic.uuid) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        } else if service.uuid == CurrentTimeService.uuid && !alreadySubscribed.contains(CurrentTimeService.uuid) {

            for characteristic in serviceCharacteristics {
                self._setTime(characteristic, currentTime: UInt32(Date().timeIntervalSince1970))
            }

        } else if service.uuid == BatteryLevelService.uuid && !alreadySubscribed.contains(BatteryLevelService.uuid) {

            /// We assume that all of characteristics are notifiable
            for characteristic in serviceCharacteristics {
                if characteristicsToSubscribe.contains(characteristic.uuid) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }

        alreadySubscribed.append(service.uuid)
    }


    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {

        if let error = error {
            self.deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didUpdateNotificationStateFor \(error.localizedDescription)"))
            return
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {

        if let error = error {
            self.deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didUpdateValueFor \(error.localizedDescription)"))
            return
        }

        guard let aidlabSDK = aidlabSDK else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didUpdateValueFor: aidlabSDK is nil"))
            return
        }

        guard let value = characteristic.value else { return }

        /// Device Information Characteristics

        if characteristic.uuid == DeviceInformationService.manufacturerNameStringCharacteristic {
            manufaturerName = String(bytes: value, encoding: String.Encoding.utf8)
        } else if characteristic.uuid == DeviceInformationService.serialNumberStringCharacteristic {

            if serialNumber != nil { return }

            serialNumber = String(bytes: value, encoding: String.Encoding.utf8)

            if firmwareRevision != nil && hardwareRevision != nil {
                didConnect()
            }

        } else if characteristic.uuid == DeviceInformationService.firmwareRevisionStringCharacteristic {

            /// security, we don't want to read revision firmware twice
            if firmwareRevision != nil { return }
            firmwareRevision = String(bytes: value, encoding: String.Encoding.utf8)
            if let firmwareRevision = firmwareRevision {
                setMaxCmdPackageLength(firmwareRevision: firmwareRevision)
                var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
                setFirmwareRevision(&fwVersion, Int32(fwVersion.count), aidlabSDK)

                if firmwareRevision.compare("3.6.62") != .orderedAscending {
                    if let heartRatePackageCharacteristic = heartRatePackageCharacteristic {
                        peripheral.setNotifyValue(false, for: heartRatePackageCharacteristic)
                    }
                }
            }

            if serialNumber != nil && hardwareRevision != nil {
                didConnect()
            }

        } else if characteristic.uuid == DeviceInformationService.hardwareRevisionStringCharacteristic {

            if hardwareRevision != nil { return }
            hardwareRevision = String(bytes: value, encoding: String.Encoding.utf8)

            if let hardwareRevision_ = hardwareRevision {
                var hwVersion: [UInt8] = Array(hardwareRevision_.utf8)
                setHardwareRevision(&hwVersion, Int32(hwVersion.count), aidlabSDK)
            }

            if serialNumber != nil && firmwareRevision != nil {
                didConnect()
            }
        }
        /// User Service Characteristics

        else if characteristic.uuid == temperatureCharacteristicUUID {

            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processTemperaturePackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == ecgCharacteristicUUID {

            lastPackageTime = NSDate().timeIntervalSince1970

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

            processBatteryPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == motionCharacteristicUUID {

            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            processMotionPackage(&scratchVal, Int32(value.count), aidlabSDK)

        } else if characteristic.uuid == cmdCharacteristicUUID {

            lastPackageTime = NSDate().timeIntervalSince1970

            var scratchVal: [UInt8] = Array(repeating: 0, count: value.count)
            (value as NSData).getBytes(&scratchVal, length: value.count)

            bytes += value.count

            processCMD(&scratchVal, Int32(value.count), aidlabSDK)

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
            processBatteryPackage(&scratchVal, Int32(value.count), aidlabSDK)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        
        guard let services = peripheral.services else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Aidlab.didDiscoverServices services is nil \(error?.localizedDescription ?? "")"))
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {

        if let error_ = error {
            self.deviceDelegate?.didReceiveError(self, error: error_)
            return
        }

        self.deviceDelegate?.didUpdateRSSI(self, rssi: RSSI.int32Value)
    }
}
