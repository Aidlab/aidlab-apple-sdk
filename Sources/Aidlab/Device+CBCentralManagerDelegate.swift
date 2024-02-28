//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023 Aidlab. All rights reserved.
//

import AidlabSDK
import CoreBluetooth
import Foundation

extension Device {
    func onFailToConnect(error: Error?) {
        deviceDelegate?.didReceiveError(self, error: AidlabError(message: "AidlabSDK: didFailToConnect \(error?.localizedDescription ?? "")"))
    }

    func onDisconnectPeripheral(timestamp _: CFAbsoluteTime, isReconnecting _: Bool, error _: Error?) {}

    func onDidConnect() {
        createAidlabSDK()

        peripheral.discoverServices(readWriteServices)

        for i in notifyServices {
            peripheral.discoverServices([i])
        }
    }

    func onDisconnectPeripheral(error: Error?) {
        alreadySubscribed.removeAll()

        var disconnectReason = DisconnectReason.deviceDisconnected

        if let error = error as NSError? {
            if error.code == 6 {
                disconnectReason = .timeout
            } else if error.code == 7 {
                disconnectReason = .deviceDisconnected
            } else {
                disconnectReason = .unknownError
            }

            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "AidlabSDK.didDisconnectPeripheral \(error.localizedDescription)"))
        }

        if !checkCompatibility() {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "AidlabSDK.didDisconnectPeripheral - unsupported SDK"))
            disconnectReason = .sdkOutdated
        }

        stopTimer()

        peripheral.delegate = nil

        AidlabSDK_did_disconnect(aidlabSDK)
        AidlabSDK_destroy(aidlabSDK)
        aidlabSDK = nil

        deviceDelegate?.didDisconnect(self, reason: disconnectReason)
        deviceDelegate = nil
    }
}
