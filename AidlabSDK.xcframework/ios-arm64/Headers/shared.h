//
//  Created by Szymon Gesicki on 29.02.2020.
//  Copyright © 2017-2024 Aidlab. All rights reserved.
//
//  Aidlab C++ SDK facilitates the process of exchanging information and receiving events from Aidlab and Aidmed One.
//  The SDK offers packet compression mechanisms, backward compatibility, filtration, and simple data analysis.
//
//  Note: Aidlab C++ SDK **does not** handle Bluetooth communication.
//

#ifndef SHARED_H__
#define SHARED_H__

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#define SHARED_EXPORT __declspec(dllexport)
#else
#define SHARED_EXPORT __attribute__((visibility("default")))
#endif

typedef enum {

    placedProperly = 0,
    placedUpsideDown = 1,
    loose = 2,
    detached = 3,
    unknown = 4,
    unsettled = 5

} WearState;

typedef enum {

    none = -1,
    pushUp = 0,
    jump = 1,
    sitUp = 2,
    burpee = 3,
    pullUp = 4,
    squat = 5,
    plankStart = 6,
    plankEnd = 7

} Exercise;

typedef enum {

    unspecific = 0,
    automotive = 1,
    walking = 2,
    running = 4,
    cycling = 8,
    still = 16

} ActivityType;

typedef enum {

    start = 0,
    end = 1,
    stop = 2,
    empty = 3,
    unavailable = 4,

} SyncState;

typedef enum { LogLevel_DEBUG = 0, LogLevel_INFO = 1, LogLevel_WARN = 2, LogLevel_ERROR = 3 } LogLevel;

typedef enum { undefined = 0, prone = 1, supine = 2, leftSide = 3, rightSide = 4 } BodyPosition;

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
typedef void (*callbackSoundFeatures)(void*, uint64_t, float*, int);
typedef void (*callbackSignalQuality)(void*, uint64_t, uint8_t);
typedef void (*callbackEda)(void*, uint64_t, float);  // timestamp, conductance (µS)
typedef void (*callbackGps)(void*, uint64_t, float, float, float, float, float, float);  // timestamp, lat, lon, alt, speed, heading, hdop
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

/// @brief Callback function type for receiving log messages from the Aidlab SDK.
/// This callback provides structured logging with proper level classification.
typedef void (*callbackLogMessage)(void* context, LogLevel level, const char* message);

/// @brief Initializes BLE communication callback for sending data to device.
/// SDK returns complete payloads ready for transmission - platform is responsible for MTU chunking.
///
/// @param bleSend Callback function for sending complete payloads to device
/// @param aidlabSDK Pointer to the Aidlab SDK instance
/// @note Platform must handle MTU-based chunking of returned payloads
/// @note BLE errors are reported through the unified callbackLogMessage system
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
/// @return Pointer to the Aidlab SDK instance.
SHARED_EXPORT void* AidlabSDK_create();

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

/// @brief Sets the structured logging callback for the Aidlab SDK.
/// This callback receives log messages with proper level classification.
///
/// @param callback Pointer to the log message callback function.
/// @param context Pointer to the context object for the callback.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_log_callback(callbackLogMessage callback, void* context, void* aidlabSDK);

// AidlabSDK_set_mtu removed - MTU handling is now platform's responsibility

/// @brief Sets the hardware revision string.
/// This function is required and should be called immediately after `AidlabSDK_create`.
///
/// @param hwRevision Pointer to the hardware revision string.
/// @param size Size of the hardware revision string.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_hardware_revision(uint8_t* hwRevision, int size, void* aidlabSDK);

/// @brief Sets the firmware revision string.
/// This function is required and should be called immediately after `AidlabSDK_create`.
///
/// @param fwRevision Pointer to the firmware revision string.
/// @param size Size of the firmware revision string.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_firmware_revision(uint8_t* fwRevision, int size, void* aidlabSDK);

/// @brief Sets the aggressive ECG filtration.
///
/// @param value Boolean value to enable/disable aggressive filtration.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_aggressive_ecg_filtration(bool value, void* aidlabSDK);
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
SHARED_EXPORT void processSoundFeaturesPackage(const uint8_t* data, int size, void* aidlabSDK);
#ifdef __cplusplus
}
#endif

#endif
