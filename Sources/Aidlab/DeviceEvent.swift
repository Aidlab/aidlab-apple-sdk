//
//  Created by Jakub Domaszewicz.
//  Copyright © 2026 Aidlab. All rights reserved.
//

import AidlabSDK

/// An event that ``DeviceDelegate/didReceiveEvent(_:event:)`` delivers, at a moment or over a period. Its identity is
/// its type, ``timestamp`` and type-specific value (for example ``EcgEvent/anntyp`` with ``EcgEvent/aux``); a later
/// event with the same identity updates the earlier one. A period still going on has no end and is reported again with
/// its end once it ends, though it may stay open, for example after a power loss.
/// A synchronized copy (``isPast`` true) updates the live one. Later SDK versions may add event types, so handle the
/// types you need and ignore the rest.
public protocol DeviceEvent: Sendable {
    /// Start, Unix time in milliseconds.
    var timestamp: UInt64 { get }
    /// End, Unix time in milliseconds: `nil` while the period lasts, equal to ``timestamp`` for a moment.
    var endTimestamp: UInt64? { get }
    /// From 0 to 1, or `nil` when the detector reports none.
    var confidence: Float? { get }
    /// True for an event read from internal memory through synchronization.
    var isPast: Bool { get }
}

/// The wear state of the chest electrodes changed. Wait for ``WearState/placedProperly`` before relying on
/// measurements.
public struct WearStateEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    public let wearState: WearState

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, wearState: WearState) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.wearState = wearState
    }
}

/// The wear state of the nasal cannula (Aidmed One) changed.
public struct PressureWearStateEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    public let wearState: WearState

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, wearState: WearState) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.wearState = wearState
    }
}

/// The wearer marked a moment, for example with the device button.
public struct UserEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
    }
}

/// The SDK detected an exercise.
public struct ExerciseEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    public let exercise: Exercise

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, exercise: Exercise) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.exercise = exercise
    }
}

/// The wearer was doing an activity over a period.
public struct ActivityEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    public let activity: ActivityType

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, activity: ActivityType) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.activity = activity
    }
}

/// One WFDB annotation of the device's ECG analysis. A beat is a moment at its R peak, with the probability of its
/// class as ``confidence``. A rhythm or noise change is a period, reported once it ends.
public struct EcgEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    /// WFDB `anntyp`: beats 1 normal (N), 5 premature ventricular contraction (V) or 13 unclassifiable (Q); 28 rhythm
    /// or 14 noise.
    public let anntyp: Int
    /// WFDB `subtyp`, 0 when none; for noise, the high four bits mark unreadable signals and the low four bits noisy
    /// ones.
    public let subtyp: Int
    /// WFDB `aux`, for example "(AFIB", or `nil` when none.
    public let aux: String?
    /// The rhythm of a rhythm or noise period, or `nil` for a beat or another annotation.
    public let rhythm: EcgRhythm?
    /// Model of the analysis as "major.minor.revision", or `nil` when unknown.
    public let modelVersion: String?

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, anntyp: Int, subtyp: Int,
                aux: String?, rhythm: EcgRhythm?, modelVersion: String?) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.anntyp = anntyp
        self.subtyp = subtyp
        self.aux = aux
        self.rhythm = rhythm
        self.modelVersion = modelVersion
    }
}

public enum EcgRhythm: Sendable {
    case atrialFibrillation
    case sinusBradycardia
    case normalSinus
    /// Unreadable or noisy signals; ``EcgEvent/subtyp`` tells which.
    case noise
    /// A rhythm that this SDK version does not know; read ``EcgEvent/anntyp`` and ``EcgEvent/aux``.
    case unknown
}

/// A period of a night analyzed by the device, reported once the night closes. A night is its periods: sleep onset is
/// the start of its first period and the final wake is the end of its last.
public struct SleepEvent: DeviceEvent {
    public let timestamp: UInt64
    public let endTimestamp: UInt64?
    public let confidence: Float?
    public let isPast: Bool
    public let period: SleepPeriod
    /// Model of the analysis as "major.minor.revision", or `nil` when unknown.
    public let modelVersion: String?

    public init(timestamp: UInt64, endTimestamp: UInt64?, confidence: Float?, isPast: Bool, period: SleepPeriod,
                modelVersion: String?) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.confidence = confidence
        self.isPast = isPast
        self.period = period
        self.modelVersion = modelVersion
    }
}

/// A period of a night; the raw value is the stage code the device reports.
public enum SleepPeriod: Int, Sendable {
    /// Awake, including waking during the night.
    case wake = 2
    case light = 3
    case deep = 4
    case rem = 5
    /// A period that this SDK version does not know.
    case unknown = -1
}

/// Converts a core event, or returns `nil` for an event type that this binding does not know.
func makeDeviceEvent(_ event: AidlabEvent, past: Bool) -> (any DeviceEvent)? {
    let timestamp = event.timestamp
    // The core marks a period still going on with end 0 and a missing confidence with a negative value.
    let end = event.endTimestamp == 0 ? nil : event.endTimestamp
    let confidence = event.confidence < 0 ? nil : event.confidence
    let aux = event.aux.map { String(cString: $0) }
    let model = modelVersion(event.modelVersion)
    return switch AidlabSDK.EventType(rawValue: event.type) {
    case AidlabSDK.eventTypeWearState:
        WearStateEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                       wearState: WearState(code: event.code))
    case AidlabSDK.eventTypePressureWearState:
        PressureWearStateEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                               wearState: WearState(code: event.code))
    case AidlabSDK.eventTypeUser:
        UserEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past)
    case AidlabSDK.eventTypeExercise:
        ExerciseEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                      exercise: Exercise(exercise: AidlabSDK.Exercise(rawValue: event.code)))
    case AidlabSDK.eventTypeActivity:
        ActivityEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                      activity: ActivityType(activityType: AidlabSDK.ActivityType(rawValue: UInt32(bitPattern: event.code))))
    case AidlabSDK.eventTypeEcg:
        EcgEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                 anntyp: Int(event.code), subtyp: Int(event.subtyp), aux: aux,
                 rhythm: EcgRhythm(anntyp: event.code, subtyp: event.subtyp, aux: aux), modelVersion: model)
    case AidlabSDK.eventTypeSleep:
        SleepEvent(timestamp: timestamp, endTimestamp: end, confidence: confidence, isPast: past,
                   period: SleepPeriod(rawValue: Int(event.code)) ?? .unknown, modelVersion: model)
    default:
        nil
    }
}

/// "major.minor.revision" of a core model version (`major << 24 | minor << 16 | revision`), or `nil` for 0.
private func modelVersion(_ version: UInt32) -> String? {
    version == 0 ? nil : "\(version >> 24).\((version >> 16) & 0xFF).\(version & 0xFFFF)"
}

private extension WearState {
    init(code: Int32) {
        self.init(wearState: AidlabSDK.WearState(rawValue: UInt32(bitPattern: code)))
    }
}

private extension EcgRhythm {
    /// The rhythm of a rhythm (28) or noise (14) annotation, or `nil` for any other annotation.
    init?(anntyp: Int32, subtyp: Int8, aux: String?) {
        switch (anntyp, aux) {
        case (28, "(AFIB"): self = .atrialFibrillation
        case (28, "(SBR"): self = .sinusBradycardia
        case (28, "(N"): self = .normalSinus
        case (14, _) where subtyp != 0: self = .noise
        case (14, _), (28, _): self = .unknown
        default: return nil
        }
    }
}
