//
//  Created by Jakub Domaszewicz on 22/12/2023.
//  Copyright © 2023-2024 Aidlab. All rights reserved.
//

import Foundation

public enum DataType: Int, Sendable {
    case ecg = 0
    case respiration = 1
    case skinTemperature = 2
    case motion = 3
    // case battery = 4 # Enabled by default since SDK 1.6.0
    case activity = 5
    case orientation = 6
    case steps = 7
    case heartRate = 8
    // case healthThermometer = 9 // No longer in use. Use skinTemperature instead.
    case soundVolume = 10
    case rr = 11
    case pressure = 12 // # Supported since Firmware 3.0.0. No longer available as characteristic.
    case soundFeatures = 13
    case respirationRate = 14
    case bodyPosition = 15
    case eda = 16
    case gps = 17
}
