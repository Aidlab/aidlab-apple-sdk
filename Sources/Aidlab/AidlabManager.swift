//
//  Created by Jakub Domaszewicz on 15.11.2016.
//  Copyright © 2016-2024 Aidlab. All rights reserved.
//

import CoreBluetooth
import Foundation

public enum DisconnectReason: Int, Sendable {
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

public final class AidlabManager: NSObject, CBCentralManagerDelegate {
    public var legacyAutoPair: Bool = true

    public init(delegate: AidlabManagerDelegate) {
        self.delegate = delegate
        shouldScan = false
        super.init()
    }

    public func scan(scanMode: ScanMode = .lowPower) {
        self.scanMode = scanMode

        if AidlabManager.centralManager == nil {
            AidlabManager.centralManager = CBCentralManager(delegate: self, queue: nil, options: nil)
        } else {
            AidlabManager.centralManager?.delegate = self
        }

        shouldScan = true

        guard let centralManager = AidlabManager.centralManager else { return }
        if !isPowerOn(central: centralManager) { return }

        centralManager.stopScan()
        centralManager.scanForPeripherals(withServices: legacyAutoPair ? servicesToScan : nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: scanMode == .aggressive])
    }

    public func stopScan() {
        shouldScan = false
        AidlabManager.centralManager?.stopScan()
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            // Nothing to do
        } else if shouldScan {
            scan(scanMode: scanMode)
        }
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoveredDevices[peripheral.identifier]?.notifyDidConnect()
    }

    public func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        discoveredDevices[peripheral.identifier]?.notifyDidFailToConnect(error: error)
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        discoveredDevices[peripheral.identifier]?.notifyDidDisconnect(error: error)
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        discoveredDevices[peripheral.identifier]?.notifyDidDisconnect(timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }

    public func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData _: [String: Any], rssi RSSI: NSNumber) {
        if let existingDevice = discoveredDevices[peripheral.identifier] {
            existingDevice.rssi = RSSI
            if existingDevice.name == nil {
                existingDevice.name = peripheral.name
            }
            delegate?.didDiscover(existingDevice)
            return
        }

        let transport =
            CoreBluetoothAidlabTransport(
                peripheral: peripheral,
                rssi: RSSI,
                centralManagerProvider: { AidlabManager.centralManager }
            )
        let newDevice = Device(transport: transport)
        discoveredDevices[peripheral.identifier] = newDevice
        delegate?.didDiscover(newDevice)
    }

    // -- Internal -------------------------------------------------------------

    nonisolated(unsafe) static var centralManager: CBCentralManager?

    // -- Private --------------------------------------------------------------

    private var discoveredDevices: [UUID: Device] = [:]

    private func isPowerOn(central: CBCentralManager) -> Bool {
        if #available(iOS 10.0, *) {
            central.state == CBManagerState.poweredOn
        } else {
            central.state.rawValue == CBCentralManagerState.poweredOn.rawValue
        }
    }

    private var shouldScan: Bool
    private weak var delegate: AidlabManagerDelegate?
    private var scanMode: ScanMode = .lowPower
    private let servicesToScan: [CBUUID] = [HeartRateService.uuid]
}
