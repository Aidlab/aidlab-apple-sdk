//
//  Created by Jakub Domaszewicz on 23/12/2023.
//

import Foundation
import AidlabSDK

public enum BodyPosition {
    internal init(bodyPosition: AidlabSDK.BodyPosition) {
        switch bodyPosition {
        case AidlabSDK.undefined:
            self = .undefined
        case AidlabSDK.front:
            self = .front
        case AidlabSDK.back:
            self = .back
        case AidlabSDK.leftSide:
            self = .leftSide
        case AidlabSDK.rightSide:
            self = .rightSide
        default:
            self = .undefined
        }
    }

    case undefined
    case front
    case back
    case leftSide
    case rightSide
}