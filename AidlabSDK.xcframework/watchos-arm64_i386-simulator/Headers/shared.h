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

typedef enum {
    oldFirmware = 0,
    crcError = 1,
    stopped = 2,
    fail = 3,
    unknownResponse = 4,
    downloadFail = 5,
    invalidSize = 6,
} UpdateError;

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
typedef void (*callbackUnsynchronizedSize)(void*, uint32_t, float);
typedef void (*callbackSyncState)(void*, SyncState);
typedef void (*callbackSignalQuality)(void*, uint64_t, uint8_t);
typedef void (*callbackUserEvent)(void*, uint64_t);
typedef void (*callback_function)(void*, Exercise);

/// @brief This callback can be safely ignored and will be removed in the next version.
typedef void (*callbackReceivedCommand)(void*);

/// @brief Callback function type for receiving messages from the device.
/// The result of this callback can be used to display messages from the device.
/// The message (message) can be converted to UTF-8.
/// Process is a numeric auxiliary value indicating from which device process the message originated.
typedef void (*callbackMessage)(void*, const char* process, const char* message);

/// @brief Callback function type for receiving errors from the device or Aidlab SDK.
typedef void (*callbackError)(void*, const char* text);

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
    callbackReceivedCommand receivedCommand, callbackMessage receivedMessage, callbackUserEvent userEvent,
    callbackPressure pressure, callbackWearState pressureWearState, callbackBodyPosition bodyPosition,
    callbackError callbackError, callbackSignalQuality signalQuality, void* aidlabSDK);

/// Initializes synchronization callbacks for historical data.
SHARED_EXPORT void AidlabSDK_init_synchronization_callbacks(
    callbackSyncState syncState, callbackUnsynchronizedSize unsynchronizedSize, callbackSampleTime pastEcg,
    callbackSampleTime pastRespiration, callbackSampleTime pastTemperature, callbackHeartRate pastHeartRate,
    callbackRr pastRr, callbackActivity pastActivity, callbackRespirationRate pastRespirationRate,
    callbackSteps pastSteps, callbackUserEvent userEvent, callbackSoundVolume soundVolume, callbackPressure pressure,
    callbackAccelerometer accelerometer, callbackGyroscope gyroscope, callbackQuaternion quaternion,
    callbackOrientation orientation, callbackMagnetometer magnetometer, callbackBodyPosition bodyPosition,
    callbackRr rr, callbackSignalQuality signalQuality, void* aidlabSDK);

/// Processes a command received from the device.
/// @param data Pointer to the command data buffer received from the Bluetooth COMMAND_CHARACTERISTIC.
/// @param size Size of the data buffer.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_process_command(const uint8_t* data, int size, void* aidlabSDK);

/// Creates a command to be sent to the device.
/// @param message Pointer to the command string.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
/// @return Pointer to the created command buffer. You should not free this buffer.
SHARED_EXPORT uint8_t* AidlabSDK_get_command(char* message, void* aidlabSDK);

/// Creates a command to collect data from the device.
/// @param realSignals Pointer to the array of real-time data signals.
/// @param realSize Size of the real-time data signals array.
/// @param syncSignals Pointer to the array of synchronized data signals.
/// @param syncSize Size of the synchronized data signals array.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
/// @return Pointer to the created collect command buffer. Send this buffer to `COMMAND_CHARACTERISTIC`.
///         Do not free this buffer as it is managed internally by the SDK.
///
/// After receiving the collect command buffer, extract the size of the command:
/// - The size is stored in the 3rd and 4th bytes of the buffer.
/// - Use the following code to retrieve the size:
///   ```c
///   int size = write_value[3] | (write_value[4] << 8);
///   ```
///
/// Send the extracted command buffer to the device:
/// - Prepare a message array using the size:
///   ```c
///   uint8_t message[size];
///   for (int i = 0; i < size; i++) {
///       message[i] = write_value[i];
///   }
///   ```
/// - Send the message array to the `COMMAND_CHARACTERISTIC` using your Bluetooth API.
SHARED_EXPORT uint8_t* AidlabSDK_get_collect_command(const uint8_t* realSignals, int realSize,
                                                     const uint8_t* syncSignals, int syncSize, void* aidlabSDK);

/// @brief Sets the context for callback identification.
/// This function allows you to attach any custom object to the Aidlab SDK instance.
/// The provided context will be passed to all callbacks, enabling you to identify
/// which device or instance sent the callback.
///
/// @param context Pointer to the custom context object.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_context(void* context, void* aidlabSDK);

/// @brief Sets the Maximum Transmission Unit (MTU) for the connection.
///
/// @param mtu MTU size.
/// @param aidlabSDK Pointer to the Aidlab SDK instance.
SHARED_EXPORT void AidlabSDK_set_mtu(uint32_t mtu, void* aidlabSDK);

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
