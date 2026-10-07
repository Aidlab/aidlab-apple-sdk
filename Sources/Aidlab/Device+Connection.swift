//
//  Created by Jakub Domaszewicz.
//  Copyright © 2026 Aidlab. All rights reserved.
//

import Foundation

extension Device {
    // Two Device objects on one address would share the link and both acknowledge every device frame.
    nonisolated(unsafe) private static var connectedDevices: [UUID: ObjectIdentifier] = [:]

    /// Reserves the address for a connection attempt; returns why the attempt cannot start.
    func beginConnectAttempt() -> AidlabError? {
        if pendingConnect != nil {
            return AidlabError(message: "Device is already connecting")
        }
        if let owner = Device.connectedDevices[address], owner != ObjectIdentifier(self) {
            return AidlabError(message: "Another Device is connected to \(address)")
        }
        Device.connectedDevices[address] = ObjectIdentifier(self)
        return nil
    }

    /// Releases the address, before didDisconnect, so that a reconnect from it can use the address.
    func releaseAddress() {
        if Device.connectedDevices[address] == ObjectIdentifier(self) {
            Device.connectedDevices[address] = nil
        }
    }

    /// Fails a pending `connect` before `didConnect`; afterwards the error reaches the delegate.
    func reportSetupError(_ error: AidlabError) {
        if let pendingConnect {
            self.pendingConnect = nil
            pendingConnect.resume(throwing: error)
        } else {
            deviceDelegate?.didReceiveError(self, error: error)
        }
    }
}
