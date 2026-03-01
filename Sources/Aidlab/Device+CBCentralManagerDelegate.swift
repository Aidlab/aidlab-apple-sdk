//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import CoreBluetooth
import Foundation

extension Device {
    public func notifyDidFailToConnect(error: Error?) {
        if let forwarding = transport as? CoreBluetoothLifecycleForwarding {
            forwarding.notifyDidFailToConnect(error: error)
            return
        }
        let resolvedError = error ?? AidlabError(message: "Fail to connect")
        deviceDelegate?.didReceiveError(self, error: resolvedError)
    }

    public func notifyDidConnect() {
        (transport as? CoreBluetoothLifecycleForwarding)?.notifyDidConnect()
    }

    public func notifyDidDisconnect(timestamp _: CFAbsoluteTime? = nil, isReconnecting _: Bool? = nil, error: Error?) {
        if let forwarding = transport as? CoreBluetoothLifecycleForwarding {
            forwarding.notifyDidDisconnect(error: error)
            return
        }
        handleDisconnected(reason: .deviceDisconnected)
    }

    // Backward-compatible aliases for in-module calls.
    func onFailToConnect(error: Error?) {
        notifyDidFailToConnect(error: error)
    }

    func onDidConnect() {
        notifyDidConnect()
    }

    func onDisconnectPeripheral(timestamp: CFAbsoluteTime?, isReconnecting: Bool?, error: Error?) {
        notifyDidDisconnect(timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }
}
