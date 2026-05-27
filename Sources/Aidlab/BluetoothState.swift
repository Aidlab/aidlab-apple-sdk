//
//  Created by Jakub Domaszewicz on 27/05/2026.
//  Copyright © 2026 Aidlab. All rights reserved.
//

import Foundation

public enum BluetoothState: Sendable {
    case unknown
    case ready
    case unsupported
    case unauthorized
    case poweredOff
}
