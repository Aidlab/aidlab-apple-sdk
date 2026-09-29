//
//  Copyright © 2026 Aidlab. All rights reserved.
//

import AidlabSDK
@preconcurrency import CoreBluetooth
import Foundation

/// Firmware before 3.6.0 streams every signal through its own characteristic.
extension Device {
    /// Firmware 2.2.6-3.5.x stores the signals whose flags `sync enable` sets. Earlier firmware stores every
    /// signal (2.2.2-2.2.4) or asks for each flag interactively (2.2.5).
    @MainActor
    func configureLegacyStorage(_ dataTypes: [DataType]) async throws {
        guard let current = firmwareVersion, let firstFlagFirmware = SemVersion("2.2.6"), current >= firstFlagFirmware else {
            return
        }
        let signals: [(token: String, dataTypes: Set<DataType>)] = [
            ("ecg", [.ecg]),
            ("respir", [.respiration, .respirationRate]),
            ("temper", [.skinTemperature]),
            ("heartR", [.heartRate, .rr]),
            ("orient", [.orientation, .bodyPosition]),
            ("accel", [.motion]),
            ("activi", [.activity]),
            ("steps", [.steps]),
        ]
        let requested = Set(dataTypes)
        let unsupported = requested.subtracting(signals.flatMap(\.dataTypes))
        guard unsupported.isEmpty else {
            let names = unsupported.map { "\($0)" }.sorted().joined(separator: ", ")
            throw AidlabError(message: "Firmware \(firmwareRevision ?? "") cannot store \(names)")
        }
        for signal in signals {
            let action = requested.isDisjoint(with: signal.dataTypes) ? "disable" : "enable"
            try await sendConfirmedLegacyCommand("sync \(action) \(signal.token)")
        }
    }

    /// Sends a legacy command and waits for the firmware to answer RECEIVED. The command holds the queue until then,
    /// so a concurrent command cannot take its confirmation.
    @MainActor
    private func sendConfirmedLegacyCommand(_ command: String, timeoutSeconds: TimeInterval = 6) async throws {
        await processCommandGate.lock()
        do {
            try await sendConfirmedLegacyCommandLocked(command, timeoutSeconds: timeoutSeconds)
            await processCommandGate.unlock()
        } catch {
            await processCommandGate.unlock()
            throw error
        }
    }

    @MainActor
    private func sendConfirmedLegacyCommandLocked(_ command: String, timeoutSeconds: TimeInterval) async throws {
        let confirmation = FrameConfirmation()
        legacyCommandConfirmation = confirmation
        defer {
            if legacyCommandConfirmation === confirmation {
                legacyCommandConfirmation = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak confirmation] in
            confirmation?.finish(.failure(AidlabError(message: "Firmware did not confirm \(command)")))
        }
        _ = try await sendProcessCommandLocked(
            commandBytes(command),
            timeoutSeconds: timeoutSeconds,
            startedProcessId: Device.syncProcessId,
            spawnedProcessId: nil,
            destinationPid: 0,
            raw: false
        )
        try await confirmation.wait()
    }

    func startLegacyCollection(dataTypes: [DataType]) {
        stopLegacyCollection()
        var uuids: Set<CBUUID> = []
        for dataType in dataTypes {
            if let uuid = dataTypesUUID[dataType] {
                uuids.insert(uuid)
            }
        }

        for uuid in uuids {
            legacyCollectionNotificationUUIDs.insert(uuid)
            startNotify(
                uuid: uuid,
                required: false,
                onData: { [weak self] data in
                    self?.processLegacyData(uuid: uuid, data: data)
                }
            )
        }
    }

    func stopLegacyCollection() {
        for uuid in legacyCollectionNotificationUUIDs {
            transport.stopNotifications(uuid)
            activeNotificationUUIDs.remove(uuid)
        }
        legacyCollectionNotificationUUIDs.removeAll(keepingCapacity: false)
    }

    private func processLegacyData(
        uuid: CBUUID,
        data: Data
    ) {
        guard aidlabSDK != nil else { return }
        var scratchVal = [UInt8](data)
        let count = Int32(scratchVal.count)

        switch uuid {
        case temperatureCharacteristicUUID:
            processTemperaturePackage(&scratchVal, count, aidlabSDK)
        case ecgCharacteristicUUID:
            processECGPackage(&scratchVal, count, aidlabSDK)
        case respirationCharacteristicUUID:
            processRespirationPackage(&scratchVal, count, aidlabSDK)
        case motionCharacteristicUUID:
            processMotionPackage(&scratchVal, count, aidlabSDK)
        case soundVolumeCharacteristicUUID:
            processSoundVolumePackage(&scratchVal, count, aidlabSDK)
        case nasalCannulaCharacteristicUUID:
            processNasalCannulaPackage(&scratchVal, count, aidlabSDK)
        case MotionService.stepsUUID:
            processStepsPackage(&scratchVal, count, aidlabSDK)
        case MotionService.activityUUID:
            processActivityPackage(&scratchVal, count, aidlabSDK)
        case MotionService.orientationUUID:
            processOrientationPackage(&scratchVal, count, aidlabSDK)
        case HeartRateService.heartRateMeasurementCharacteristic:
            processHeartRatePackage(&scratchVal, count, aidlabSDK)
        case BatteryLevelService.batteryLevelCharacteristic, batteryCharacteristicUUID:
            AidlabSDK_process_battery_package(&scratchVal, count, aidlabSDK)
        default:
            break
        }
    }
}
