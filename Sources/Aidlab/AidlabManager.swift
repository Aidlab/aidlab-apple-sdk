//
//  Created by J Domaszewicz on 15.11.2016.
//  Copyright © 2016-2023 Aidlab. All rights reserved.
//
import CoreBluetooth
import Foundation

public enum ECGFiltrationMethod {
    case normal
    case aggressive
}

public enum DisconnectReason: Int {
    case timeout = 0
    case deviceDisconnected = 1
    case appDisconnected = 2
    case sdkOutdated = 3
    case unknownError = 4
}

public enum ScanMode: Int {
    case lowPower = 0
    case aggressive = 1
}

public class AidlabManager: NSObject, CBCentralManagerDelegate {
    // -- Config ----------------------------------------

    public var legacyAutoPair: Bool = true

    private let peripheralName = "Aidlab"

    public init(delegate: AidlabManagerDelegate) {
        self.delegate = delegate

        shouldScan = false

        super.init()
    }

    public func scan(scanMode: ScanMode = .lowPower) {
        self.scanMode = scanMode

        /// CBCentralManager call's for Bluetooth permision
        /// that's why we initialize it here.
        if AidlabManager.centralManager == nil {
            AidlabManager.centralManager = CBCentralManager(delegate: self, queue: nil, options: nil)
        } else {
            AidlabManager.centralManager?.delegate = self
        }

        shouldScan = true

        guard let centralManager = AidlabManager.centralManager else { return }

        if !isPowerOn(central: centralManager) { return }

        centralManager.stopScan()

        centralManager.scanForPeripherals(withServices: legacyAutoPair ? servicesToScan : nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: scanMode == .aggressive ? true : false])
    }

    public func stopScan() {
        shouldScan = false
        AidlabManager.centralManager?.stopScan()
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            /// Nothing to do

        } else if shouldScan {
            scan(scanMode: scanMode)
        }
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoveredDevices[peripheral.identifier]?.onDidConnect()
    }

    public func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        discoveredDevices[peripheral.identifier]?.onFailToConnect(error: error)
        discoveredDevices[peripheral.identifier] = nil
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        discoveredDevices[peripheral.identifier]?.onDisconnectPeripheral(error: error)
        discoveredDevices[peripheral.identifier] = nil
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        discoveredDevices[peripheral.identifier]?.onDisconnectPeripheral(timestamp: timestamp, isReconnecting: isReconnecting, error: error)
        discoveredDevices[peripheral.identifier] = nil
    }

    public func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData _: [String: Any], rssi RSSI: NSNumber) {
        if let existingDevice = discoveredDevices[peripheral.identifier] {
            existingDevice.rssi = RSSI
        } else if peripheral.name == peripheralName {
            let newDevice = Device(peripheral: peripheral, rssi: RSSI)
            discoveredDevices[peripheral.identifier] = newDevice
            delegate?.didDiscover(newDevice)
        }
    }

    var discoveredDevices: [UUID: Device] = [:]

    // -- Private ---------------------------------------------------------------

    private func isPowerOn(central: CBCentralManager) -> Bool {
        if #available(iOS 10.0, *) {
            central.state == CBManagerState.poweredOn
        } else {
            central.state.rawValue == CBCentralManagerState.poweredOn.rawValue
        }
    }

    /// _centralManager is static now, as nilling this property was leading to
    /// `[CoreBluetooth] XPC connection invalid` and crash when device was
    /// trying to connect with peripheral. Different approaches was examined:
    /// * cleaning _centralManager after X seconds
    /// * stopping the scan
    /// * waiting for power off (centralManagerDidUpdateState)
    /// yet nothing helped. Apple's docs and Google don't state if
    /// CBCentralManager can be nilled or not.
    static var centralManager: CBCentralManager?

    private var shouldScan: Bool

    private var delegate: AidlabManagerDelegate?

    private var scanMode: ScanMode = .lowPower

    private let servicesToScan: [CBUUID] = [HeartRateService.uuid]
}
