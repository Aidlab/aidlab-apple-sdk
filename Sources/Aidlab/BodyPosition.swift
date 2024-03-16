//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum BodyPosition {
    init(bodyPosition: AidlabSDK.BodyPosition) {
        switch bodyPosition {
        case AidlabSDK.undefined:
            self = .undefined
        case AidlabSDK.prone:
            self = .prone
        case AidlabSDK.supine:
            self = .supine
        case AidlabSDK.leftSide:
            self = .leftSide
        case AidlabSDK.rightSide:
            self = .rightSide
        default:
            self = .undefined
        }
    }

    case undefined
    case prone
    case supine
    case leftSide
    case rightSide
}
