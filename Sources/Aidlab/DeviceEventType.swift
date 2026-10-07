//
//  Created by Jakub Domaszewicz.
//  Copyright © 2026 Aidlab. All rights reserved.
//

/// Events that the device detects itself; list them in the `events` of
/// ``Device/collect(dataTypes:dataTypesToStore:events:)``. Aidlab 2 detects them from firmware 4.0.0.
public enum DeviceEventType: Int, Sendable {
    /// ``EcgEvent``: beats, rhythm and noise periods.
    case ecg = 5
    /// ``SleepEvent``: the night and its stages.
    case sleep = 6
}
