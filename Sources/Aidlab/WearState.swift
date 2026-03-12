//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum WearState {
    init(wearState: AidlabSDK.WearState) {
        switch wearState {
        case AidlabSDK.wearStatePlacedProperly:
            self = .placedProperly
        case AidlabSDK.wearStatePlacedUpsideDown:
            self = .placedUpsideDown
        case AidlabSDK.wearStateLoose:
            self = .loose
        case AidlabSDK.wearStateDetached:
            self = .detached
        case AidlabSDK.wearStateUnknown:
            self = .unknown
        case AidlabSDK.wearStateUnsettled:
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
