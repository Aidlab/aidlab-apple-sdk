//
//  Created by Jakub Domaszewicz on 21/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import CoreBluetooth
import Foundation

public extension Device {
    func notifyDidFailToConnect(error: Error?) {
        onMainQueue { [self] in
            if let forwarding = transport as? CoreBluetoothLifecycleForwarding {
                forwarding.notifyDidFailToConnect(error: error)
                return
            }
            let resolvedError = error.map(AidlabError.wrapping) ?? AidlabError(message: "Fail to connect")
            deviceDelegate?.didReceiveError(self, error: resolvedError)
        }
    }

    func notifyDidConnect() {
        onMainQueue { [self] in
            (transport as? CoreBluetoothLifecycleForwarding)?.notifyDidConnect()
        }
    }

    func notifyDidDisconnect(timestamp _: CFAbsoluteTime? = nil, isReconnecting _: Bool? = nil, error: Error?) {
        onMainQueue { [self] in
            if let forwarding = transport as? CoreBluetoothLifecycleForwarding {
                forwarding.notifyDidDisconnect(error: error)
                return
            }
            handleDisconnected(reason: .deviceDisconnected)
        }
    }
}
