//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import CoreBluetooth
import Foundation

extension Device {
    func onFailToConnect(error: Error?) {
        if let error {
            deviceDelegate?.didReceiveError(self, error: error)
        } else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Fail to connect"))
        }
    }

    func onDisconnectPeripheral(timestamp _: CFAbsoluteTime, isReconnecting _: Bool, error _: Error?) {}

    func onDidConnect() {
        peripheral.discoverServices(readWriteServices)

        for i in notifyServices {
            peripheral.discoverServices([i])
        }
    }

    func onDisconnectPeripheral(error: Error?) {
        var disconnectReason = DisconnectReason.deviceDisconnected

        if let error = error as NSError? {
            if error.code == 6 {
                disconnectReason = .timeout
            } else if error.code == 7 {
                disconnectReason = .deviceDisconnected
            } else {
                disconnectReason = .unknownError
            }

            deviceDelegate?.didReceiveError(self, error: error)
        }

        if !checkCompatibility() {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Unsupported SDK"))
            disconnectReason = .sdkOutdated
        }

        peripheral.delegate = nil

        AidlabSDK_destroy(aidlabSDK)
        aidlabSDK = nil

        deviceDelegate?.didDisconnect(self, reason: disconnectReason)
        deviceDelegate = nil
    }
}
