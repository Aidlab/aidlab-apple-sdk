//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum ActivityType {
    init(activityType: AidlabSDK.ActivityType) {
        switch activityType {
        case AidlabSDK.unspecific:
            self = .unspecific
        case AidlabSDK.automotive:
            self = .automotive
        case AidlabSDK.walking:
            self = .walking
        case AidlabSDK.running:
            self = .running
        case AidlabSDK.cycling:
            self = .cycling
        case AidlabSDK.still:
            self = .still
        default:
            self = .unspecific
        }
    }

    case unspecific
    case automotive
    case walking
    case running
    case cycling
    case still
}
