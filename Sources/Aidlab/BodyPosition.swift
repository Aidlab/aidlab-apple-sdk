//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum BodyPosition {
    init(bodyPosition: AidlabSDK.BodyPosition) {
        switch bodyPosition {
        case AidlabSDK.bodyPositionUnknown:
            self = .unknown
        case AidlabSDK.bodyPositionProne:
            self = .prone
        case AidlabSDK.bodyPositionSupine:
            self = .supine
        case AidlabSDK.bodyPositionLeftSide:
            self = .leftSide
        case AidlabSDK.bodyPositionRightSide:
            self = .rightSide
        default:
            self = .unknown
        }
    }

    case unknown
    case prone
    case supine
    case leftSide
    case rightSide
}
