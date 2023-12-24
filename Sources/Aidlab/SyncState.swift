//
//  Created by Jakub Domaszewicz on 23/12/2023.
//

import AidlabSDK
import Foundation

public enum SyncState {
    init(syncState: AidlabSDK.SyncState) {
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
