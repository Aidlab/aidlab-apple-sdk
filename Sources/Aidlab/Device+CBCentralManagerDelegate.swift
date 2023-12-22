//
//  Created by Jakub Domaszewicz on 21/12/2023.
//

import Foundation
import CoreBluetooth
import AidlabSDK

extension Device {

    internal func onFailToConnect(error: Error?) {

        deviceDelegate?.didReceiveError(self, error: AidlabError(message: "AidlabSDK: didFailToConnect \(error?.localizedDescription ?? "")"))
    }

    internal func onDisconnectPeripheral(timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {

    }

    internal func onDidConnect() {

        createAidlabSDK()

        peripheral.discoverServices(readWriteServices)

        for i in notifyServices {
            peripheral.discoverServices([i])
        }
    }

    internal func onDisconnectPeripheral(error: Error?) {

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

        AidlabSDK_destroy(aidlabSDK)
        AidlabSDK_did_disconnect(aidlabSDK)
        aidlabSDK = nil

        deviceDelegate?.didDisconnect(self, reason: disconnectReason)
        deviceDelegate = nil
    }
}
