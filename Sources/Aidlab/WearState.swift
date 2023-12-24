//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum WearState {
    init(wearState: AidlabSDK.WearState) {
        switch wearState {
        case AidlabSDK.placedProperly:
            self = .placedProperly
        case AidlabSDK.placedUpsideDown:
            self = .placedUpsideDown
        case AidlabSDK.loose:
            self = .loose
        case AidlabSDK.detached:
            self = .detached
        case AidlabSDK.unknown:
            self = .unknown
        case AidlabSDK.unsettled:
            self = .unsettled
        default:
            self = .unknown
        }
    }

    case placedProperly
    case placedUpsideDown
    case loose
    case detached
    case unknown
    case unsettled
}
