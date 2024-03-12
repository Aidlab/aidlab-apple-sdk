//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum Exercise {
    init(exercise: AidlabSDK.Exercise) {
        switch exercise {
        case AidlabSDK.none:
            self = .none
        case AidlabSDK.pushUp:
            self = .pushUp
        case AidlabSDK.jump:
            self = .jump
        case AidlabSDK.sitUp:
            self = .sitUp
        case AidlabSDK.burpee:
            self = .burpee
        case AidlabSDK.pullUp:
            self = .pullUp
        case AidlabSDK.squat:
            self = .squat
        case AidlabSDK.plankStart:
            self = .plankStart
        case AidlabSDK.plankEnd:
            self = .plankEnd
        default:
            self = .none
        }
    }

    case none
    case pushUp
    case jump
    case sitUp
    case burpee
    case pullUp
    case squat
    case plankStart
    case plankEnd
}
