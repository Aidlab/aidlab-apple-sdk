//
//  Created by Jakub Domaszewicz.
//  Copyright © 2026 Aidlab. All rights reserved.
//

/// Events to report; list them in the `events` of ``Device/collect(dataTypes:dataTypesToStore:events:)``.
public enum DeviceEventType: Int, Sendable {
    /// ``WearStateEvent``: the wear state of the chest electrodes.
    case wearState = 0
    /// ``PressureWearStateEvent``: the wear state of the nasal cannula (Aidmed One).
    case pressureWearState = 1
    /// ``UserEvent``: moments the wearer marked.
    case user = 2
    /// ``ExerciseEvent``: exercises the SDK detected.
    case exercise = 3
    /// ``ActivityEvent``: activity periods.
    case activity = 4
    /// ``EcgEvent``: beats, rhythm and noise periods.
    case ecg = 5
    /// ``SleepEvent``: the stages of a night.
    case sleep = 6
}
