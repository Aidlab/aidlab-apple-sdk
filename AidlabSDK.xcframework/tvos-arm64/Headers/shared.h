//
//  Created by Szymon Gesicki on 29.02.2020.
//  Copyright © 2017-2026 Aidlab. All rights reserved.
//
//  Aidlab C++ SDK facilitates the process of exchanging information and receiving events from Aidlab and Aidmed One.
//  The SDK offers packet compression mechanisms, backward compatibility, filtration, and simple data analysis.
//
//  Note: Aidlab C++ SDK **does not** handle Bluetooth communication.
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
    exercisePlankStart = 6,
    exercisePlankEnd = 7

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
    AIDLAB_ERROR_TRANSPORT = 1000,
    AIDLAB_ERROR_PROTOCOL = 2000,
    AIDLAB_ERROR_SDK = 9000
} AidlabErrorCode;

typedef enum {
    bodyPositionUnknown = 0,
    bodyPositionProne = 1,
    bodyPositionSupine = 2,
    bodyPositionLeftSide = 3,
    bodyPositionRightSide = 4
} BodyPosition;

typedef void (*callbackSampleTime)(void*, uint64_t, float);
typedef void (*callbackActivity)(void*, uint64_t, ActivityType);
typedef void (*callbackRespirationRate)(void*, uint64_t, uint32_t);
typedef void (*callbackSteps)(void*, uint64_t, uint64_t);
typedef void (*callbackBatteryLevel)(void*, uint8_t);
typedef void (*callbackWearState)(void*, WearState);
typedef void (*callbackAccelerometer)(void*, uint64_t, float, float, float);
typedef void (*callbackGyroscope)(void*, uint64_t, float, float, float);
typedef void (*callbackMagnetometer)(void*, uint64_t, float, float, float);
typedef void (*callbackOrientation)(void*, uint64_t, float, float, float);
typedef void (*callbackBodyPosition)(void*, uint64_t, BodyPosition);
typedef void (*callbackQuaternion)(void*, uint64_t, float, float, float, float);
typedef void (*callbackHeartRate)(void*, uint64_t, int);
typedef void (*callbackRr)(void*, uint64_t, int);
typedef void (*callbackSoundVolume)(void*, uint64_t, uint16_t);
typedef void (*callbackPressure)(void*, uint64_t, int);
typedef void (*callbackSignalQuality)(void*, uint64_t, uint8_t);
typedef void (*callbackEda)(void*, uint64_t, float);  // timestamp, conductance (µS)
typedef void (*callbackGps)(void*, uint64_t, float, float, float, float, float,
                            float);  // timestamp, lat, lon, alt, speed (m/s), heading, hdop
typedef void (*callbackUnsynchronizedSize)(void*, uint32_t, float);
typedef void (*callbackSyncState)(void*, SyncState);
typedef void (*callbackUserEvent)(void*, uint64_t);
typedef void (*callback_function)(void*, Exercise);

////////////////////////////////
/// BLE Communication Callbacks ///
////////////////////////////////

/// @brief Callback function type for sending complete payloads to the device.
/// SDK returns full payloads with protocol headers - platform must chunk to MTU size.
/// Implementation should split payload into MTU-sized chunks and write to BLE command characteristic.
typedef void (*callbackBLESend)(void* context, const uint8_t* data, int size);

/// @brief Callback invoked when BLE transport is ready to accept the next payload.
/// Legacy protocols (V1–V3.1) trigger it immediately after framing, V4 triggers it after ACK (when enabled).
typedef void (*callbackBLEReady)(void* context);

/// @brief Callback function type for receiving payloads from the device.
/// This callback delivers the raw payload data after transport protocol headers are stripped.
/// Process parameter indicates which device process originated the payload.
typedef void (*callbackPayload)(void* context, const char* process, const uint8_t* payload, size_t payload_length);

/// @brief Callback function type for receiving typed SDK errors.
/// Code is the public contract. Message is diagnostic-only and must not be parsed by consumers.
typedef void (*callbackError)(void* context, AidlabErrorCode code, const char* message);

/// @brief Initializes BLE communication callback for sending data to device.
/// SDK returns complete payloads ready for transmission - platform is responsible for MTU chunking.
///
/// @param bleSend Callback function for sending complete payloads to device
/// @param aidlabSDK Pointer to the Aidlab SDK instance
/// @note Platform must handle MTU-based chunking of returned payloads
/// @note BLE errors are reported through AidlabSDK_set_error_callback.
SHARED_EXPORT void AidlabSDK_set_ble_send_callback(callbackBLESend bleSend, void* aidlabSDK);

/// @brief Registers BLE ready callback that notifies when it is safe to transmit the next payload.
///
/// @param bleReady Callback to invoke on ready state
/// @param aidlabSDK Pointer to the Aidlab SDK instance
SHARED_EXPORT void AidlabSDK_set_ble_ready_callback(callbackBLEReady bleReady, void* aidlabSDK);

/// @brief Automatically detects protocol version and processes chunk accordingly:
/// - V1: Direct sensor data processing (no headers)
/// - V2/V3: Legacy header parsing and packet assembly
/// - V4: Modern protocol with compression and CRC validation
///
/// @param data Pointer to the received BLE chunk data
/// @param size Size of the received chunk in bytes
/// @param aidlabSDK Pointer to the Aidlab SDK instance
SHARED_EXPORT void AidlabSDK_process_ble_chunk(const uint8_t* data, int size, void* aidlabSDK);

/// Creates a new instance of Aidlab SDK.
/// Each device should have a unique instance of AidlabSDK.
/// This should be created upon successful connection to the device and discovery of all device's Bluetooth services.
///
/// @param fwRevision Pointer to the firmware revision string (UTF-8, not null-terminated required)
/// @param size Size of the firmware revision string.
/// @return Pointer to the Aidlab SDK instance, or nullptr when firmware revision is invalid.
SHARED_EXPORT void* AidlabSDK_create(const uint8_t* fwRevision, int size);

/// Destroys the Aidlab SDK instance.
/// Should be called after disconnecting from the device.
SHARED_EXPORT void AidlabSDK_destroy(void* aidlabSDK);

/// Initializes the callbacks.
SHARED_EXPORT void AidlabSDK_init_callbacks(
    callbackSampleTime ecg, callbackSampleTime respiration, callbackSampleTime temperature,
    callbackAccelerometer accelerometer, callbackGyroscope gyroscope, callbackMagnetometer magnetometer,
    callbackBatteryLevel battery, callbackActivity activity, callbackSteps steps, callbackOrientation orientation,
    callbackQuaternion quaternion, callbackRespirationRate respirationRate, callbackWearState wearState,
    callbackHeartRate heartRate, callbackRr rr, callbackSoundVolume soundVolume, callback_function exercise,
    callbackUserEvent userEvent, callbackPressure pressure, callbackWearState pressureWearState,
    callbackBodyPosition bodyPosition, callbackSignalQuality signalQuality, void* aidlabSDK);

/// Initializes synchronization callbacks for historical data.
SHARED_EXPORT void AidlabSDK_init_synchronization_callbacks(
    callbackSyncState syncState, callbackUnsynchronizedSize unsynchronizedSize, callbackSampleTime pastEcg,
    callbackSampleTime pastRespiration, callbackSampleTime pastTemperature, callbackHeartRate pastHeartRate,
    callbackRr pastRr, callbackActivity pastActivity, callbackRespirationRate pastRespirationRate,
    callbackSteps pastSteps, callbackUserEvent userEvent, callbackSoundVolume soundVolume, callbackPressure pressure,
    callbackAccelerometer accelerometer, callbackGyroscope gyroscope, callbackQuaternion quaternion,
    callbackOrientation orientation, callbackMagnetometer magnetometer, callbackBodyPosition bodyPosition,
    callbackSignalQuality signalQuality, void* aidlabSDK);

/// @brief Sets the context for callback identification.
/// This function allows you to attach any custom object to the Aidlab SDK instance.
/// The provided context will be passed to all callbacks, enabling you to identify
/// which device or instance sent the callback.
///
/// @param context Pointer to the custom context object.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_context(void* context, void* aidlabSDK);

SHARED_EXPORT void AidlabSDK_set_payload_callback(callbackPayload callback, void* aidlabSDK);

/// @brief Sets the typed SDK error callback.
/// TRANSPORT and PROTOCOL errors indicate that the current communication session is unreliable.
/// Consumers should reset the connection/session before retrying application-level commands.
SHARED_EXPORT void AidlabSDK_set_error_callback(callbackError callback, void* context, void* aidlabSDK);

SHARED_EXPORT void AidlabSDK_set_eda_callback(callbackEda eda, void* aidlabSDK);
SHARED_EXPORT void AidlabSDK_set_gps_callback(callbackGps gps, void* aidlabSDK);
SHARED_EXPORT void AidlabSDK_set_past_eda_callback(callbackEda eda, void* aidlabSDK);
SHARED_EXPORT void AidlabSDK_set_past_gps_callback(callbackGps gps, void* aidlabSDK);

/// @brief Sends payload to device.
/// SDK adds protocol headers and returns complete payload via callbackBLESend.
/// Platform is responsible for chunking the payload to fit MTU size.
///
/// @param payload Pointer to the payload data to send (without protocol headers)
/// @param size Size of the payload buffer in bytes
/// @param process_id Process identifier for routing
/// @param aidlabSDK Pointer to the Aidlab SDK instance
/// @note Requires callbackBLESend to be set via AidlabSDK_set_ble_send_callback()
/// @note Platform must chunk returned payload according to negotiated MTU
/// @note SDK handles protocol framing - do not add headers manually
SHARED_EXPORT void AidlabSDK_send(const uint8_t* payload, int size, int process_id, void* aidlabSDK);

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
