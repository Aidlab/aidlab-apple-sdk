//
//  Created by Jakub Domaszewicz on 23/12/2023.
//

import Foundation
import AidlabSDK

public enum ActivityType {
    internal init(activityType: AidlabSDK.ActivityType) {
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
