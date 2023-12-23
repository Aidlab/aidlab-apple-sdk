//
//  Created by Jakub Domaszewicz on 23/12/2023.
//

import Foundation
import AidlabSDK

public enum SyncState {
    internal init(syncState: AidlabSDK.SyncState) {
        switch syncState {
        case AidlabSDK.start:
            self = .start
        case AidlabSDK.end:
            self = .end
        case AidlabSDK.stop:
            self = .stop
        case AidlabSDK.empty:
            self = .empty
        case AidlabSDK.unavailable:
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
