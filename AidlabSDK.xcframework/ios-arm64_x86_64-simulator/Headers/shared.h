//
//  Created by Szymon Gesicki on 29.02.2020.
//  Copyright © 2017-2023 Aidlab. All rights reserved.
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

SHARED_EXPORT void* AidlabSDK_create();

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

typedef enum { undefined = 0, front = 1, back = 2, leftSide = 3, rightSide = 4 } BodyPosition;

typedef void (*callbackReceivedCommand)(void*);
typedef void (*callbackSampleTime)(void*, uint64_t, float);
typedef void (*callbackSamplesTime)(void*, uint64_t, float*, int);
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
typedef void (*callbackPressure)(void*, uint64_t, int*, int);
typedef void (*callbackSoundFeatures)(void*, float*, int);
typedef void (*callbackSignalQuality)(void*, uint64_t, uint8_t);
typedef void (*callbackUnsynchronizedSize)(void*, uint32_t, float);
typedef void (*callbackSyncState)(void*, SyncState);
typedef void (*callbackSignalQuality)(void*, uint64_t, uint8_t);
typedef void (*callbackMessage)(void*, const char* process, const char* message);
typedef void (*callbackUserEvent)(void*, uint64_t);
typedef void (*callbackError)(void*, const char* text);
typedef void (*callback_function)(void*, Exercise);

SHARED_EXPORT void AidlabSDK_init_callbacks(
    callbackSamplesTime ecg, callbackSamplesTime respiration, callbackSampleTime temperature,
    callbackAccelerometer accelerometer, callbackGyroscope gyroscope, callbackMagnetometer magnetometer,
    callbackBatteryLevel battery, callbackActivity activity, callbackSteps steps, callbackOrientation orientation,
    callbackQuaternion quaternion, callbackRespirationRate respirationRate, callbackWearState wearState,
    callbackHeartRate heartRate, callbackRr rr, callbackSoundVolume soundVolume, callback_function exercise,
    callbackReceivedCommand receivedCommand, callbackMessage receivedMessage, callbackUserEvent userEvent,
    callbackPressure pressure, callbackWearState pressureWearState, callbackBodyPosition bodyPosition,
    callbackError callbackError, callbackSignalQuality signalQuality, void* aidlabSDK, void* context);

SHARED_EXPORT void AidlabSDK_init_synchronization_callbacks(
    callbackSyncState syncState, callbackUnsynchronizedSize unsynchronizedSize, callbackSamplesTime pastEcg,
    callbackSamplesTime pastRespiration, callbackSampleTime pastTemperature, callbackHeartRate pastHeartRate,
    callbackRr pastRr, callbackActivity pastActivity, callbackRespirationRate pastRespirationRate,
    callbackSteps pastSteps, callbackUserEvent userEvent, callbackSoundVolume soundVolume, callbackPressure pressure,
    callbackAccelerometer accelerometer, callbackGyroscope gyroscope, callbackQuaternion quaternion,
    callbackOrientation orientation, callbackMagnetometer magnetometer, callbackBodyPosition bodyPosition,
    callbackRr rr, callbackSignalQuality signalQuality, void* aidlabSDK, void* context);

SHARED_EXPORT void processECGPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processTemperaturePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processActivityPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processBatteryPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processMotionPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processRespirationPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processStepsPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processOrientationPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processHealthThermometerPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processHeartRatePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processSoundVolumePackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processCMD(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void setHardwareRevision(uint8_t* hwRevision, int size, void* aidlabSDK);
SHARED_EXPORT void setFirmwareRevision(uint8_t* fwRevision, int size, void* aidlabSDK);
SHARED_EXPORT void processNasalCannulaPackage(const uint8_t* data, int size, void* aidlabSDK);
SHARED_EXPORT void processSoundFeaturesPackage(const uint8_t* data, int size, void* aidlabSDK);

SHARED_EXPORT void AidlabSDK_did_connect(void* aidlabSDK);
SHARED_EXPORT void AidlabSDK_did_disconnect(void* aidlabSDK);

SHARED_EXPORT void setAggressiveECGFiltration(bool value, void* aidlabSDK);
SHARED_EXPORT uint8_t* get_command(char* message, void* aidlabSDK);
SHARED_EXPORT uint8_t* get_collect_command(const uint8_t* realSignals, int realSize, const uint8_t* syncSignals,
                                           int syncSize, void* aidlabSDK);
SHARED_EXPORT void AidlabSDK_destroy(void* aidlabSDK);
SHARED_EXPORT void internalProcessCMD(
    const uint8_t* data, int size, callbackSamplesTime ecg, callbackSamplesTime respiration,
    callbackSampleTime temperature, callbackAccelerometer accelerometer, callbackGyroscope gyroscope,
    callbackMagnetometer magnetometer, callbackBatteryLevel battery, callbackActivity activity, callbackSteps steps,
    callbackOrientation orientation, callbackQuaternion quaternion, callbackRespirationRate respirationRate,
    callbackWearState wearState, callbackHeartRate heartRate, callbackRr rr, callbackSoundVolume soundVolume,
    callback_function exercise, callbackReceivedCommand receivedCommand, callbackMessage receivedMessage,
    callbackUserEvent userEvent, callbackPressure pressure, callbackWearState pressureWearState,
    callbackBodyPosition bodyPosition, callbackError callbackError, callbackSignalQuality signalQuality,
    void* aidlabSDK, void* context);

#ifdef __cplusplus
}
#endif

#endif
