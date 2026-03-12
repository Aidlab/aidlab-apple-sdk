//
//  Created by Jakub Domaszewicz on 23/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import AidlabSDK
import Foundation

public enum Exercise: Int {
    init(exercise: AidlabSDK.Exercise) {
        switch exercise {
        case AidlabSDK.exerciseNone:
            self = .none
        case AidlabSDK.exercisePushUp:
            self = .pushUp
        case AidlabSDK.exerciseJump:
            self = .jump
        case AidlabSDK.exerciseSitUp:
            self = .sitUp
        case AidlabSDK.exerciseBurpee:
            self = .burpee
        case AidlabSDK.exercisePullUp:
            self = .pullUp
        case AidlabSDK.exerciseSquat:
            self = .squat
        case AidlabSDK.exercisePlankStart:
            self = .plankStart
        case AidlabSDK.exercisePlankEnd:
            self = .plankEnd
        default:
            self = .none
        }
    }

    case none = -1
    case pushUp = 0
    case jump = 1
    case sitUp = 2
    case burpee = 3
    case pullUp = 4
    case squat = 5
    case plankStart = 6
    case plankEnd = 7
}
