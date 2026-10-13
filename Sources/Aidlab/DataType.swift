//
//  Created by Jakub Domaszewicz on 22/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import Foundation

public enum DataType: Int, Sendable {
    // Raw values 4, 5, 9 and 13 are reserved by the device protocol; 5 is activity, which collect adds for
    // DeviceEventType.activity.
    case ecg = 0
    case respiration = 1
    case skinTemperature = 2
    case motion = 3
    case orientation = 6
    case steps = 7
    case heartRate = 8
    case soundVolume = 10
    case rr = 11
    case pressure = 12
    case respirationRate = 14
    case bodyPosition = 15
    case eda = 16
    case gps = 17
}
