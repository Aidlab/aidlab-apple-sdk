//
//  Created by Szymon Gesicki on 29.02.2020.
//  Copyright © 2017-2026 Aidlab. All rights reserved.
//
//  Aidlab C++ SDK facilitates the process of exchanging information and receiving events from Aidlab and Aidmed One.
//  The SDK offers packet compression mechanisms, backward compatibility, filtration, and simple data analysis.
//
//  Note: Aidlab C++ SDK **does not** handle Bluetooth communication.
//
//  Threading: an SDK instance is not thread-safe. Serialize every call for one instance. Callbacks run synchronously on
//  the calling thread, inside AidlabSDK_process_ble_chunk or AidlabSDK_send. Do not call AidlabSDK_destroy from a
//  callback; defer it until the SDK call that invoked the callback has returned.
//

#ifndef SHARED_H_
#define SHARED_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#define SHARED_EXPORT __declspec(dllexport)
#else
#define SHARED_EXPORT __attribute__((visibility("default")))
#endif

typedef enum {

    wearStatePlacedProperly = 0,
    wearStatePlacedUpsideDown = 1,
    wearStateLoose = 2,
    wearStateDetached = 3,
    wearStateUnknown = 4,
    wearStateUnsettled = 5

} WearState;

typedef enum {

    exerciseNone = -1,
    exercisePushUp = 0,
    exerciseJump = 1,
    exerciseSitUp = 2,
    exerciseBurpee = 3,
    exercisePullUp = 4,
    exerciseSquat = 5,
    exercisePlank = 6

} Exercise;

typedef enum {

    activityTypeUnknown = 0,
    activityTypeAutomotive = 1,
    activityTypeWalking = 2,
    activityTypeRunning = 4,
    activityTypeCycling = 8,
    activityTypeStill = 16

} ActivityType;

typedef enum {

    syncStateStart = 0,
    syncStateEnd = 1,
    syncStateStop = 2,
    syncStateEmpty = 3,
    syncStateUnavailable = 4,

} SyncState;

typedef enum {
    AIDLAB_ERROR_NONE = 0,
    /// Link failure detected by the platform integration (failed write, ACK deadline). The core does not emit it.
    AIDLAB_ERROR_TRANSPORT = 1000,
    /// The device sent data that violates the transport protocol. The session is unreliable.
    AIDLAB_ERROR_PROTOCOL = 2000,
    /// Local SDK condition, for example invalid arguments, a send while a V4 frame awaits ACK/NAK, or device data
    /// that the SDK drops because no process can admit or decode it. Nothing is wrong with the link and the session
    /// remains usable.
    AIDLAB_ERROR_SDK = 9000
} AidlabErrorCode;

typedef enum {
    bodyPositionUnknown = 0,
    bodyPositionProne = 1,
    bodyPositionSupine = 2,
    bodyPositionLeftSide = 3,
    bodyPositionRightSide = 4
} BodyPosition;

/// The events the SDK reports. Events are delivered live only when listed in collect (AidlabSDK_set_events); events
/// read through synchronization are always delivered.
typedef enum {
    /// The wear state of the chest electrodes changed. `code` is the new WearState.
    eventTypeWearState = 0,
    /// The wear state of the nasal cannula (Aidmed One) changed. `code` is the new WearState.
    eventTypePressureWearState = 1,
    /// The wearer marked a moment, for example with the device button. `code` is 0.
    eventTypeUser = 2,
    /// The SDK detected an exercise. `code` is the Exercise.
    eventTypeExercise = 3,
    /// The wearer was doing an activity. `code` is the ActivityType.
    eventTypeActivity = 4,
    /// One WFDB annotation of the device's ECG analysis. `code` is the WFDB `anntyp`. A beat is a moment at its R peak:
    /// 1 normal (N), 5 premature ventricular contraction (V), 9 supraventricular premature beat (S) or 13
    /// unclassifiable (Q), with the probability of that class as `confidence`. A rhythm or noise change is a period,
    /// reported once it ends: 28 (rhythm) with `aux` "(AFIB" (atrial fibrillation) or "(SBR" (sinus bradycardia), or 14
    /// (noise), whose `subtyp` marks unreadable signals in its high four bits and noisy ones in its low four bits; the
    /// period ends at the return to "(N" or to `subtyp` 0.
    eventTypeEcg = 5,
    /// A period of a night analyzed by the device. `code` is its stage: 2 awake, 3 light, 4 deep or 5 REM; 1 is
    /// reserved for sleep without a stage. A night is its periods: sleep onset is the start of its first period and the
    /// final wake is the end of its last.
    eventTypeSleep = 6
} EventType;

/// An event that happened at a moment or over a period. Its identity is `type`, `timestamp`, `code` and `aux`; a later
/// event with the same identity updates the earlier one. A period that is still going on is reported with
/// `endTimestamp` 0, and again with its end once it ends. A period may stay open, for example after a power loss.
/// An event read through synchronization (`past` true) updates the same event reported live.
/// Later versions may append fields, so read it through the pointer the SDK passes and do not copy or allocate it.
typedef struct {
    uint32_t type;          // EventType
    int32_t code;           // Meaning depends on the type
    uint64_t timestamp;     // Start, Unix time in milliseconds
    uint64_t endTimestamp;  // End, equal to `timestamp` for a moment and 0 while the period lasts
    float confidence;       // From 0 to 1, or negative when the detector reports none
    uint32_t modelVersion;  // Model of an on-device analysis, major << 24 | minor << 16 | revision; 0 for none
    const char* aux;        // WFDB `aux`, a NUL-terminated ASCII string, or null when the event has none
    int8_t subtyp;          // WFDB `subtyp`, 0 when the event has none
} AidlabEvent;

/// Data callbacks take `past` after the context: false for live data, true for data read from internal memory
/// through synchronization.
typedef void (*callbackSampleTime)(void*, bool, uint64_t, float);
typedef void (*callbackRespirationRate)(void*, bool, uint64_t, uint32_t);
typedef void (*callbackSteps)(void*, bool, uint64_t, uint64_t);
typedef void (*callbackBatteryLevel)(void*, uint8_t);
typedef void (*callbackAccelerometer)(void*, bool, uint64_t, float, float, float);
typedef void (*callbackGyroscope)(void*, bool, uint64_t, float, float, float);
typedef void (*callbackMagnetometer)(void*, bool, uint64_t, float, float, float);
typedef void (*callbackOrientation)(void*, bool, uint64_t, float, float, float);
typedef void (*callbackBodyPosition)(void*, bool, uint64_t, BodyPosition);
typedef void (*callbackQuaternion)(void*, bool, uint64_t, float, float, float, float);
typedef void (*callbackHeartRate)(void*, bool, uint64_t, int);
typedef void (*callbackRr)(void*, bool, uint64_t, int);
typedef void (*callbackSoundVolume)(void*, bool, uint64_t, uint16_t);
typedef void (*callbackPressure)(void*, bool, uint64_t, int);
typedef void (*callbackSignalQuality)(void*, bool, uint64_t, uint8_t);
typedef void (*callbackEda)(void*, bool, uint64_t, float);  // timestamp, conductance (µS)
typedef void (*callbackGps)(void*, bool, uint64_t, float, float, float, float, float,
                            float);  // timestamp, lat, lon, alt, speed (m/s), heading, hdop
/// Remaining synchronization data in bytes and the transfer speed in bytes per second, or -1 while unknown.
typedef void (*callbackUnsynchronizedSize)(void*, uint32_t, float);
typedef void (*callbackSyncState)(void*, SyncState);
/// Events take `past` after the context, like data callbacks. The event is valid only during the call.
typedef void (*callbackEvent)(void*, bool, const AidlabEvent*);

////////////////////////////////
/// BLE Communication Callbacks ///
////////////////////////////////

/// @brief Callback function type for sending complete payloads to the device.
/// SDK returns full payloads with protocol headers. The platform must split each frame into sequential GATT writes
/// no larger than min(negotiated ATT MTU - 3, 512) and write them to the BLE command characteristic.
typedef void (*callbackBLESend)(void* context, const uint8_t* data, int size);

/// @brief Callback invoked when BLE transport is ready to accept the next payload.
/// The public send API requests ACK/NAK for V4 frames, and this callback fires after that transaction resolves.
/// Legacy protocols do not have a protocol-level ready callback; their platform writes use GATT write responses.
typedef void (*callbackBLEReady)(void* context);

/// @brief Callback reporting how the device resolved the V4 frame that is awaiting ACK/NAK.
/// It fires once per resolved frame, immediately before callbackBLEReady. Result 0 means the device acknowledged the
/// frame. Any other value is the error byte of the device NAK (see src/Communication/src/v4/README.md); a NAK rejects
/// that frame and must not be retried automatically. Legacy protocols (V1-V3) have no ACK/NAK and never invoke it.
typedef void (*callbackBLEFrameResult)(void* context, uint8_t result);

/// @brief Callback function type for receiving payloads from the device.
/// This callback delivers the raw payload data after transport protocol headers are stripped.
/// Options contains the process-specific metadata received from the device.
/// A response may span multiple callbacks; callback boundaries do not define text lines.
/// PID identifies the runtime process instance; legacy protocols without PIDs report zero.
typedef void (*callbackPayload)(void* context, uint16_t pid, const uint8_t* payload, size_t payload_length,
                                uint64_t options);

/// @brief Callback invoked for stderr emitted by a device process.
/// PID identifies the runtime process instance. Payload is raw process output and is not necessarily NUL-terminated.
typedef void (*callbackProcessError)(void* context, uint16_t pid, const uint8_t* payload, size_t payload_length,
                                     uint64_t options);

/// @brief Callback function type for receiving typed SDK errors.
/// Code is the public contract. Message is diagnostic-only and must not be parsed by consumers.
typedef void (*callbackError)(void* context, AidlabErrorCode code, const char* message);

/// @brief Initializes BLE communication callback for sending data to device.
/// SDK returns complete payloads ready for transmission; platform is responsible for legal ATT chunking.
///
/// @param bleSend Callback function for sending complete payloads to device
/// @param aidlabSDK Pointer to the Aidlab SDK instance
/// @note Each GATT write must be no larger than min(negotiated ATT MTU - 3, 512).
/// @note BLE errors are reported through AidlabSDK_set_error_callback.
SHARED_EXPORT void AidlabSDK_set_ble_send_callback(callbackBLESend bleSend, void* aidlabSDK);

/// @brief Registers BLE ready callback that notifies when it is safe to transmit the next payload.
///
/// @param bleReady Callback to invoke on ready state
/// @param aidlabSDK Pointer to the Aidlab SDK instance
SHARED_EXPORT void AidlabSDK_set_ble_ready_callback(callbackBLEReady bleReady, void* aidlabSDK);

/// @brief Registers the V4 frame result callback, which distinguishes ACK from NAK for the frame in flight.
///
/// @param frameResult Callback to invoke with the frame result
/// @param aidlabSDK Pointer to the Aidlab SDK instance
SHARED_EXPORT void AidlabSDK_set_ble_frame_result_callback(callbackBLEFrameResult frameResult, void* aidlabSDK);

/// @brief Automatically detects protocol version and processes chunk accordingly:
/// - V1-V3: Legacy header parsing and packet assembly
/// - V4: Modern protocol with optional compression and per-frame ACK/NAK
///
/// @param data Pointer to the received BLE chunk data
/// @param size Size of the received chunk in bytes
/// @param aidlabSDK Pointer to the Aidlab SDK instance
SHARED_EXPORT void AidlabSDK_process_ble_chunk(const uint8_t* data, int size, void* aidlabSDK);

/// @brief Reports that the host platform failed to write the last SDK-produced BLE frame locally.
///
/// Use this only when the platform can prove that no byte of the frame reached the peer. If a fragmented frame may
/// have been partially written, discard queued writes and disconnect so both endpoints reset their session state.
SHARED_EXPORT void AidlabSDK_notify_ble_send_failure(void* aidlabSDK);

/// Creates a new instance of Aidlab SDK.
/// Each device should have a unique instance of AidlabSDK.
/// This should be created upon successful connection to the device and discovery of all device's Bluetooth services.
///
/// @param fwRevision Pointer to the firmware revision bytes (UTF-8). A null terminator is not required; bytes from the
/// first null byte onward are ignored.
/// @param size Size of the firmware revision buffer.
/// @return Pointer to the Aidlab SDK instance, or nullptr when firmware revision is invalid.
SHARED_EXPORT void* AidlabSDK_create(const uint8_t* fwRevision, int size);

/// Destroys the Aidlab SDK instance.
/// Should be called after disconnecting from the device.
SHARED_EXPORT void AidlabSDK_destroy(void* aidlabSDK);

/// Initializes the callbacks. Data and event callbacks receive both live and synchronized data.
SHARED_EXPORT void AidlabSDK_init_callbacks(callbackSampleTime ecg, callbackSampleTime respiration,
                                            callbackSampleTime temperature, callbackAccelerometer accelerometer,
                                            callbackGyroscope gyroscope, callbackMagnetometer magnetometer,
                                            callbackBatteryLevel battery, callbackSteps steps,
                                            callbackOrientation orientation, callbackQuaternion quaternion,
                                            callbackRespirationRate respirationRate, callbackHeartRate heartRate,
                                            callbackRr rr, callbackSoundVolume soundVolume, callbackPressure pressure,
                                            callbackBodyPosition bodyPosition, callbackSignalQuality signalQuality,
                                            callbackEda eda, callbackGps gps, callbackEvent event, void* aidlabSDK);

/// Returns the data types in `dataTypes` that the firmware of this device does not support. Both masks set bit `n` for
/// the data type with value `n`, as the collect flags do. Reserved data types are never supported.
SHARED_EXPORT uint64_t AidlabSDK_unsupported_data_types(uint64_t dataTypes, const void* aidlabSDK);

/// Returns the event types in `events` that the SDK cannot report for this device. Both masks set bit `n` for the
/// EventType with value `n`. Each event type has a minimum firmware; eventTypeEcg and eventTypeSleep need Aidlab 2
/// (firmware 4.0.0 and newer), and eventTypePressureWearState needs pressure, which only Aidmed One measures.
SHARED_EXPORT uint64_t AidlabSDK_unsupported_events(uint64_t events, const void* aidlabSDK);

/// Turns the data types and events requested from collect into the masks of `collect flags <live> <store> <events>`.
/// `live` and `store` set bit `n` for the data type with value `n`, `events` bit `n` for the EventType with value `n`.
/// Adds to `live` and `store` the data types the events need: activity (5) to both for eventTypeActivity, pressure to
/// `live` for eventTypePressureWearState, motion and orientation to `live` for eventTypeExercise. Leaves in `events`
/// only the on-device detectors, eventTypeEcg and eventTypeSleep.
SHARED_EXPORT void AidlabSDK_collect_flags(uint64_t* live, uint64_t* store, uint64_t* events, const void* aidlabSDK);

/// Sets the events the event callback reports live, as a mask with bit `n` for the EventType with value `n`, and
/// returns the previous mask; other live events are dropped. Events read through synchronization are always reported.
/// Collect sets the events it lists and restores the previous mask when it fails. A new instance reports no live
/// events.
SHARED_EXPORT uint64_t AidlabSDK_set_events(uint64_t events, void* aidlabSDK);

/// Initializes the synchronization progress callbacks.
SHARED_EXPORT void AidlabSDK_init_synchronization_callbacks(callbackSyncState syncState,
                                                            callbackUnsynchronizedSize unsynchronizedSize,
                                                            void* aidlabSDK);

/// @brief Sets the context for callback identification.
/// This function allows you to attach any custom object to the Aidlab SDK instance.
/// The provided context will be passed to all callbacks, enabling you to identify
/// which device or instance sent the callback.
///
/// @param context Pointer to the custom context object.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_context(void* context, void* aidlabSDK);

SHARED_EXPORT void AidlabSDK_set_payload_callback(callbackPayload callback, void* aidlabSDK);

SHARED_EXPORT void AidlabSDK_set_process_error_callback(callbackProcessError callback, void* aidlabSDK);

/// @brief Sets the typed SDK error callback.
/// TRANSPORT and PROTOCOL errors indicate that the current communication session is unreliable.
/// Consumers should reset the connection/session before retrying application-level commands.
/// Reset outside the callback: AidlabSDK_destroy must not run while the SDK is still inside the call that reported it.
SHARED_EXPORT void AidlabSDK_set_error_callback(callbackError callback, void* context, void* aidlabSDK);

/// @brief Sends payload to device. The public V4 send path requests transport ACK/NAK for every frame.
/// Legacy Aidlab 1 transports (V1-V3) do not support protocol ACK/NAK; platform integrations must use GATT writes
/// with response for their fixed 20-byte command chunks.
/// SDK adds protocol headers and returns complete payload via callbackBLESend.
/// Platform is responsible for chunking the payload to the legal ATT value length.
///
/// @param payload Pointer to the payload data to send (without protocol headers)
/// @param size Size of the payload buffer in bytes
/// @param destination_pid Runtime destination PID for routing; use 0 for shell/system commands
/// @param aidlabSDK Pointer to the Aidlab SDK instance
/// @note An empty payload closes the process's stdin (end of file); to PID 0 it is an error.
/// @note Requires callbackBLESend to be set via AidlabSDK_set_ble_send_callback()
/// @note Each GATT write must be no larger than min(negotiated ATT MTU - 3, 512).
/// @note SDK handles protocol framing - do not add headers manually
SHARED_EXPORT void AidlabSDK_send(const uint8_t* payload, int size, int destination_pid, void* aidlabSDK);

/// @internal Platform bridge for high-level process control methods. Public raw send APIs use AidlabSDK_send().
/// Preserves the legacy command/data header distinction when routing a control command to an active process PID.
SHARED_EXPORT void AidlabSDK_send_process_command(const uint8_t* payload, int size, int destination_pid,
                                                  void* aidlabSDK);

////////////////////////////////
/// Legacy (<FW 3.6 methods) ///
////////////////////////////////

/// @deprecated Use standard Bluetooth Battery Service to read battery level.
/// Processes a battery package received from the device.
/// @param data Pointer to the battery data buffer.
/// @param size Size of the data buffer.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_process_battery_package(const uint8_t* data, int size, void* aidlabSDK);

SHARED_EXPORT void processECGPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processTemperaturePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processActivityPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processMotionPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processRespirationPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processStepsPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processOrientationPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processHealthThermometerPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processHeartRatePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processSoundVolumePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processNasalCannulaPackage(const uint8_t* data, int size, void* aidlabSDK);
#ifdef __cplusplus
}
#endif

#endif
