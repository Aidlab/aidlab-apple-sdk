//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum ActivityType {
    init(activityType: AidlabSDK.ActivityType) {
        switch activityType {
        case AidlabSDK.activityTypeUnknown:
            self = .unknown
        case AidlabSDK.activityTypeAutomotive:
            self = .automotive
        case AidlabSDK.activityTypeWalking:
            self = .walking
        case AidlabSDK.activityTypeRunning:
            self = .running
        case AidlabSDK.activityTypeCycling:
            self = .cycling
        case AidlabSDK.activityTypeStill:
            self = .still
        default:
            self = .unknown
        }
    }

    case unknown
    case automotive
    case walking
    case running
    case cycling
    case still
}
