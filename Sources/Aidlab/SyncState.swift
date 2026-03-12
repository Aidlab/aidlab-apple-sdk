//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum SyncState {
    init(syncState: AidlabSDK.SyncState) {
        switch syncState {
        case AidlabSDK.syncStateStart:
            self = .start
        case AidlabSDK.syncStateEnd:
            self = .end
        case AidlabSDK.syncStateStop:
            self = .stop
        case AidlabSDK.syncStateEmpty:
            self = .empty
        case AidlabSDK.syncStateUnavailable:
            self = .unavailable
        default:
            self = .unavailable
        }
    }

    case start
    case end
    case stop
    case empty
    case unavailable
}
