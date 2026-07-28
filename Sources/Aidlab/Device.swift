//
//  Created by J Domaszewicz on 10.11.2016.
//  Copyright © 2016-2024 Aidlab. All rights reserved.
//

import AidlabSDK
@preconcurrency import CoreBluetooth
import Foundation

private final class FrameConfirmation: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private struct QueuedBLEChunk {
    let data: Data
    let completesFrame: Bool
}

private actor ProcessCommandGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

public class Device: NSObject, @unchecked Sendable {
    private static let systemCreateSuccess: UInt8 = 0
    private static let systemCreateFailure: UInt8 = 1
    private static let systemKillSuccess: UInt8 = 2
    private static let systemKillFailure: UInt8 = 3
    private static let syncProcessId: UInt8 = 7
    private static let collectProcessId: UInt8 = 8
    private static let frameConfirmationTimeout: TimeInterval = 3

    public var name: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var serialNumber: String?
    public var manufacturerName: String?
    public var address: UUID
    public var rssi: NSNumber {
        get { transport.rssi }
        set { transport.rssi = newValue }
    }

    let transport: AidlabTransport
    private var activeNotificationUUIDs: Set<CBUUID> = []
    private var legacyCollectionNotificationUUIDs: Set<CBUUID> = []
    private var didHandleDisconnect = false
    private let processCommandGate = ProcessCommandGate()
    private let commandStateLock = NSLock()
    private var pendingProcessCommand: PendingProcessCommand?
    private var pendingProcessTermination: PendingProcessTermination?
    private var activeProcessPids: [UInt8: UInt16] = [:]
    /// Backwards-compatible access to the underlying CoreBluetooth peripheral, if applicable.
    public var peripheral: CBPeripheral? {
        (transport as? CoreBluetoothAidlabTransport)?.peripheral
    }

    public init(transport: AidlabTransport) {
        self.transport = transport
        address = transport.address
        name = transport.name
        super.init()

        if let coreBluetoothTransport = transport as? CoreBluetoothAidlabTransport {
            coreBluetoothTransport.onRSSIRead = { [weak self] rssi in
                guard let self else { return }
                deviceDelegate?.didUpdateRSSI(self, rssi: rssi.int32Value)
            }
        }
    }

    public convenience init(peripheral: CBPeripheral, rssi: NSNumber) {
        let defaultTransport =
            CoreBluetoothAidlabTransport(
                peripheral: peripheral,
                rssi: rssi,
                centralManagerProvider: { AidlabManager.centralManager }
            )
        self.init(transport: defaultTransport)
    }

    public convenience init(peripheral: CBPeripheral, rssi: NSNumber, centralManager: CBCentralManager) {
        let defaultTransport =
            CoreBluetoothAidlabTransport(
                peripheral: peripheral,
                rssi: rssi,
                centralManager: centralManager
            )
        self.init(transport: defaultTransport)
    }

    public func connect(delegate: DeviceDelegate) {
        deviceDelegate = delegate
        resetBleQueue()
        didHandleDisconnect = false
        stopAllNotifications()

        transport.onDisconnect = { [weak self] reason, error in
            guard let self else { return }
            if let error {
                deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
            }
            handleDisconnected(reason: reason)
        }

        transport.connect { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                onTransportConnected()
            case let .failure(error):
                deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
            }
        }
    }

    public func disconnect() {
        resetBleQueue()
        transport.disconnect()
    }

    public func collect(dataTypes: [DataType], dataTypesToStore: [DataType]) async throws -> UInt16? {
        guard aidlabSDK != nil else {
            throw AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API.")
        }

        guard let firmwareRevision, let firmwareSemantic = SemVersion(firmwareRevision), let legacySemanticVersion = SemVersion("3.6.0") else {
            throw AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API.")
        }

        if firmwareSemantic >= legacySemanticVersion {
            // Build flags from signal arrays (use bit flags)
            var liveFlags: UInt32 = 0
            var syncFlags: UInt32 = 0

            for signal in dataTypes {
                liveFlags |= 1 << signal.rawValue
            }

            for signal in dataTypesToStore {
                syncFlags |= 1 << signal.rawValue
            }

            // Check firmware version to determine collect format
            if let firmwareVersion3780 = SemVersion("3.7.80"), firmwareSemantic >= firmwareVersion3780 {
                // CollectSettingsString - newer firmware expects string format
                let liveHex = String(format: "%08X", liveFlags)
                let syncHex = String(format: "%08X", syncFlags)
                let collectCommand = "collect flags \(liveHex) \(syncHex)"
                let activeCollectPid = activePid(for: Device.collectProcessId)
                return try await sendProcessCommand(
                    commandBytes(collectCommand),
                    spawnedProcessId: hasCollectAutoSyncBug() ? Device.syncProcessId : nil,
                    destinationPid: activeCollectPid ?? 0
                )
            } else {
                // Build binary command for older firmware
                let prefix = "collect on "
                var buffer = Array(prefix.utf8)

                // Add live flags (4 bytes, big-endian)
                buffer.append(UInt8((liveFlags >> 24) & 0xFF))
                buffer.append(UInt8((liveFlags >> 16) & 0xFF))
                buffer.append(UInt8((liveFlags >> 8) & 0xFF))
                buffer.append(UInt8((liveFlags >> 0) & 0xFF))

                // Add sync flags (4 bytes, big-endian)
                buffer.append(UInt8((syncFlags >> 24) & 0xFF))
                buffer.append(UInt8((syncFlags >> 16) & 0xFF))
                buffer.append(UInt8((syncFlags >> 8) & 0xFF))
                buffer.append(UInt8((syncFlags >> 0) & 0xFF))

                let activeCollectPid = activePid(for: Device.collectProcessId)
                return try await sendProcessCommand(buffer, destinationPid: activeCollectPid ?? 0)
            }

        } else { /// Legacy
            startLegacyCollection(dataTypes: dataTypes)
            return nil
        }
    }

    public func readRSSI() {
        guard let peripheral else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "RSSI not available for this transport"))
            return
        }
        peripheral.readRSSI()
    }

    public func startSynchronization() async throws -> UInt16? {
        try await sendProcessCommand(commandBytes(synchronizationStartCommand()))
    }

    public func stopSynchronization() async throws -> UInt16? {
        let activePid = activePid(for: Device.syncProcessId)
        if let activePid {
            return try await sendActiveProcessCommand(commandBytes("sync stop"), pid: activePid)
        }
        return nil
    }

    public func clearSynchronization() async throws -> UInt16? {
        try await sendProcessCommand(commandBytes("sync clear"))
    }

    public func stopCollect() async throws -> UInt16? {
        guard let firmwareRevision,
              let firmware = SemVersion(firmwareRevision),
              let processCollectionVersion = SemVersion("3.6.0")
        else {
            throw AidlabError(message: "Firmware revision is unavailable")
        }
        if firmware < processCollectionVersion {
            stopLegacyCollection()
            return nil
        }
        guard let collectPid = activePid(for: Device.collectProcessId) else {
            return nil
        }
        return try await sendProcessCommand(commandBytes("collect off"), destinationPid: collectPid)
    }

    public func setTime(_ timestamp: UInt32) {
        let payload = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
        transport.writeCharacteristic(
            CurrentTimeService.currentTimeCharacteristic,
            data: payload,
            withResponse: true
        ) { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
            }
        }
    }

    /// Sends a raw payload to a runtime destination PID. Use processId 0 for shell/system commands.
    public func send(_ bytes: [UInt8], processId: Int = 0) {
        guard let aidlabSDK, !bytes.isEmpty else { return }
        guard beginFrameConfirmation() != nil else {
            deviceDelegate?.didReceiveError(
                self,
                error: AidlabError(message: "Previous BLE frame is not confirmed")
            )
            return
        }
        var payload = bytes
        guard emitTrackedFrame({
            AidlabSDK_send(&payload, Int32(payload.count), Int32(processId), aidlabSDK)
        }) else {
            failFrameTransmission(AidlabError(message: "SDK rejected the BLE frame"))
            return
        }
    }

    // -- Internal -------------------------------------------------------------

    // Avoid implicitly unwrapped optional; use optional and guard when needed
    var aidlabSDK: UnsafeMutableRawPointer?
    var deviceDelegate: DeviceDelegate?

    var maxCmdPackageLength: Int = 20

    // BLE transport state (chunk queue handled on the main actor)
    private var chunkQueue: [QueuedBLEChunk] = []
    var readyForNextChunk: Bool = true
    private let frameConfirmationLock = NSLock()
    private var awaitingFrameConfirmation = false
    private var frameConfirmationGeneration: UInt64 = 0
    private var frameConfirmationDeadline: DispatchWorkItem?
    private var currentFrameConfirmation: FrameConfirmation?
    private var expectedFrameCallbackThread: ObjectIdentifier?

    private func startNotify(
        uuid: CBUUID,
        required: Bool,
        onData: @escaping (Data) -> Void
    ) {
        activeNotificationUUIDs.insert(uuid)
        transport.startNotifications(
            uuid,
            onData: onData,
            onError: { [weak self] error in
                guard let self else { return }
                if required {
                    deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
                    transport.disconnect()
                }
            }
        )
    }

    private func stopAllNotifications() {
        for uuid in activeNotificationUUIDs {
            transport.stopNotifications(uuid)
        }
        activeNotificationUUIDs.removeAll(keepingCapacity: false)
        legacyCollectionNotificationUUIDs.removeAll(keepingCapacity: false)
    }

    func onTransportConnected() {
        readConnectionMetadata { [weak self] in
            self?.didConnect()
        }
    }

    func handleDisconnected(reason: DisconnectReason) {
        if didHandleDisconnect {
            return
        }
        didHandleDisconnect = true
        completePendingProcessCommand(.failure(AidlabError(message: "Device disconnected")))
        completePendingProcessTermination(.failure(AidlabError(message: "Device disconnected")))
        commandStateLock.lock()
        activeProcessPids.removeAll()
        commandStateLock.unlock()

        var resolvedReason = reason
        if !checkCompatibility() {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Unsupported SDK"))
            resolvedReason = .sdkOutdated
        }

        stopAllNotifications()
        resetBleQueue()

        if let aidlabSDK {
            AidlabSDK_set_error_callback(nil, nil, aidlabSDK)
            AidlabSDK_set_context(nil, aidlabSDK)
            AidlabSDK_destroy(aidlabSDK)
        }
        aidlabSDK = nil

        deviceDelegate?.didDisconnect(self, reason: resolvedReason)
        deviceDelegate = nil
        transport.onDisconnect = nil
    }

    private func readConnectionMetadata(completion: @escaping () -> Void) {
        func readUtf8(_ uuid: CBUUID, completion: @escaping (String?) -> Void) {
            transport.readCharacteristic(uuid) { result in
                switch result {
                case let .success(data):
                    let value = String(bytes: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\0", with: "") ?? ""
                    completion(value.isEmpty ? nil : value)
                case .failure:
                    completion(nil)
                }
            }
        }

        readUtf8(DeviceInformationService.manufacturerNameStringCharacteristic) { [weak self] value in
            guard let self else { return }
            manufacturerName = value
            readUtf8(DeviceInformationService.serialNumberStringCharacteristic) { [weak self] value in
                guard let self else { return }
                serialNumber = value
                readUtf8(DeviceInformationService.firmwareRevisionStringCharacteristic) { [weak self] value in
                    guard let self else { return }
                    firmwareRevision = value
                    readUtf8(DeviceInformationService.hardwareRevisionStringCharacteristic) { [weak self] value in
                        guard let self else { return }
                        hardwareRevision = value

                        guard serialNumber != nil, firmwareRevision != nil, hardwareRevision != nil else {
                            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Failed to read device metadata"))
                            transport.disconnect()
                            return
                        }

                        completion()
                    }
                }
            }
        }
    }

    /// Serial number, firmware, and hardware version are ready
    private func didConnect() {
        if !checkCompatibility() {
            deviceDelegate?.didConnect(self)
            disconnect()
            return
        }

        setTime(UInt32(Date().timeIntervalSince1970))

        createAidlabSDK()

        if usesV4Protocol() {
            let negotiated = transport.mtuSize
            maxCmdPackageLength = min(512, max(20, negotiated > 0 ? negotiated : 20))
        } else {
            maxCmdPackageLength = 20
        }
        startNotify(
            uuid: cmdCharacteristicUUID,
            required: true,
            onData: { [weak self] data in
                self?.processCommandChunk(data)
            }
        )
        drainChunkQueue()

        startNotify(
            uuid: BatteryLevelService.batteryLevelCharacteristic,
            required: false,
            onData: { [weak self] data in
                self?.processBatteryPacket(data)
            }
        )

        /// Users are notified about the connection after reading the firmware revision
        deviceDelegate?.didConnect(self)
    }

    func createAidlabSDK() {
        guard let firmwareRevision else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Missing firmware revision"))
            return
        }

        var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
        aidlabSDK = AidlabSDK_create(&fwVersion, Int32(fwVersion.count))
        resetBleQueue()

        guard let aidlabSDK else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Internal error"))
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AidlabSDK_set_context(context, aidlabSDK)
        AidlabSDK_set_error_callback(didReceiveError, context, aidlabSDK)

        AidlabSDK_set_ble_send_callback(bleSendCallback, aidlabSDK)
        AidlabSDK_set_ble_ready_callback(bleReadyCallback, aidlabSDK)

        AidlabSDK_init_callbacks(didReceiveECG,
                                 didReceiveRespiration,
                                 didReceiveSkinTemperature,
                                 didReceiveAccelerometer,
                                 didReceiveGyroscope,
                                 didReceiveMagnetometer,
                                 didReceiveBatteryLevel,
                                 didDetectActivity,
                                 didReceiveSteps,
                                 didReceiveOrientation,
                                 didReceiveQuaternion,
                                 didReceiveRespirationRate,
                                 wearStateDidChange,
                                 didReceiveHeartRate,
                                 didReceiveRr,
                                 didReceiveSoundVolume,
                                 didDetect,
                                 didDetectUserEvent,
                                 didReceivePressure,
                                 pressureWearStateDidChange,
                                 didReceiveBodyPosition,
                                 didReceiveSignalQuality,
                                 aidlabSDK)

        AidlabSDK_set_eda_callback(didReceiveEDA, aidlabSDK)
        AidlabSDK_set_gps_callback(didReceiveGPS, aidlabSDK)

        AidlabSDK_set_payload_callback(didReceivePayload, aidlabSDK)
        AidlabSDK_set_process_error_callback(didReceiveProcessError, aidlabSDK)

        AidlabSDK_init_synchronization_callbacks(syncStateDidChange, didReceiveUnsynchronizedSize, didReceivePastECG, didReceivePastRespiration, didReceivePastSkinTemperature, didReceivePastHeartRate, didReceivePastRr, didReceivePastActivity, didReceivePastRespirationRate, didReceivePastSteps, didDetectPastUserEvent, didReceivePastSoundVolume, didReceivePastPressure, didReceivePastAccelerometer, didReceivePastGyroscope, didReceivePastQuaternion, didReceivePastOrientation, didReceivePastMagnetometer, didReceivePastBodyPosition, didReceivePastSignalQuality, aidlabSDK)
        AidlabSDK_set_past_eda_callback(didReceivePastEDA, aidlabSDK)
        AidlabSDK_set_past_gps_callback(didReceivePastGPS, aidlabSDK)
    }

    func checkCompatibility() -> Bool {
        guard let version = firmwareRevision else { return true }
        let stringArray = version.split(separator: ".")
        let minor = Int(stringArray[1]) ?? 0
        return Config.supportedAidlabVersion >= minor ? true : false
    }

    // -- Private --------------------------------------------------------------

    private func sendRawBleData(_ data: [UInt8], completesFrame: Bool) {
        guard !data.isEmpty else { return }

        let chunkSize = resolvedChunkSize()
        var offset = 0

        while offset < data.count {
            let endIndex = min(offset + chunkSize, data.count)
            let chunk = Data(data[offset ..< endIndex])
            chunkQueue.append(
                QueuedBLEChunk(
                    data: chunk,
                    completesFrame: completesFrame && endIndex == data.count
                )
            )
            offset = endIndex
        }

        drainChunkQueue()
    }

    private func resolvedChunkSize() -> Int {
        guard usesV4Protocol() else {
            return 20
        }

        let negotiated = transport.mtuSize
        if negotiated > 0 {
            return min(512, min(maxCmdPackageLength, max(20, negotiated)))
        }
        return 20
    }

    func resetBleQueue() {
        chunkQueue.removeAll(keepingCapacity: false)
        readyForNextChunk = true
        completeFrameConfirmation(error: AidlabError(message: "BLE frame was reset"))
    }

    private func beginFrameConfirmation() -> FrameConfirmation? {
        frameConfirmationLock.lock()
        guard !awaitingFrameConfirmation else {
            frameConfirmationLock.unlock()
            return nil
        }
        let confirmation = FrameConfirmation()
        awaitingFrameConfirmation = true
        currentFrameConfirmation = confirmation
        frameConfirmationGeneration &+= 1
        let previousDeadline = frameConfirmationDeadline
        frameConfirmationDeadline = nil
        frameConfirmationLock.unlock()
        previousDeadline?.cancel()
        return confirmation
    }

    private func emitTrackedFrame(_ action: () -> Void) -> Bool {
        let thread = ObjectIdentifier(Thread.current)
        frameConfirmationLock.lock()
        expectedFrameCallbackThread = thread
        frameConfirmationLock.unlock()

        action()

        frameConfirmationLock.lock()
        let emitted = expectedFrameCallbackThread != thread
        if !emitted {
            expectedFrameCallbackThread = nil
        }
        frameConfirmationLock.unlock()
        return emitted
    }

    private func consumeTrackedFrameCallback() -> Bool {
        let thread = ObjectIdentifier(Thread.current)
        frameConfirmationLock.lock()
        let tracked = expectedFrameCallbackThread == thread
        if tracked {
            expectedFrameCallbackThread = nil
        }
        frameConfirmationLock.unlock()
        return tracked
    }

    private func armFrameConfirmationDeadline() {
        if !usesV4Protocol() {
            completeFrameConfirmation()
            return
        }

        frameConfirmationLock.lock()
        guard awaitingFrameConfirmation else {
            frameConfirmationLock.unlock()
            return
        }

        frameConfirmationGeneration &+= 1
        let generation = frameConfirmationGeneration
        let previousDeadline = frameConfirmationDeadline
        let deadline = DispatchWorkItem { [weak self] in
            self?.frameConfirmationDidTimeout(generation: generation)
        }
        frameConfirmationDeadline = deadline
        frameConfirmationLock.unlock()

        previousDeadline?.cancel()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Device.frameConfirmationTimeout,
            execute: deadline
        )
    }

    private func completeFrameConfirmation(error: Error? = nil) {
        frameConfirmationLock.lock()
        awaitingFrameConfirmation = false
        frameConfirmationGeneration &+= 1
        let deadline = frameConfirmationDeadline
        let confirmation = currentFrameConfirmation
        frameConfirmationDeadline = nil
        currentFrameConfirmation = nil
        expectedFrameCallbackThread = nil
        frameConfirmationLock.unlock()
        deadline?.cancel()
        if let error {
            confirmation?.finish(.failure(error))
        } else {
            confirmation?.finish(.success(()))
        }
    }

    private func failFrameTransmission(_ error: AidlabError) {
        chunkQueue.removeAll(keepingCapacity: false)
        readyForNextChunk = true
        completeFrameConfirmation(error: error)
        deviceDelegate?.didReceiveError(self, error: error)
        transport.disconnect()
    }

    private func frameConfirmationDidTimeout(generation: UInt64) {
        frameConfirmationLock.lock()
        guard awaitingFrameConfirmation, frameConfirmationGeneration == generation else {
            frameConfirmationLock.unlock()
            return
        }
        frameConfirmationLock.unlock()
        failFrameTransmission(AidlabError(message: "BLE frame confirmation timed out"))
    }

    private struct SystemProcessResult {
        let status: UInt8
        let pid: UInt16
        let processId: UInt8?

        var accepted: Bool {
            status == Device.systemCreateSuccess
        }
    }

    private final class PendingProcessCommand: @unchecked Sendable {
        let continuation: CheckedContinuation<SystemProcessResult?, Error>
        let spawnedProcessId: UInt8?
        var responseReceived: Bool
        var response: SystemProcessResult?

        init(
            continuation: CheckedContinuation<SystemProcessResult?, Error>,
            spawnedProcessId: UInt8?,
            responseReceived: Bool
        ) {
            self.continuation = continuation
            self.spawnedProcessId = spawnedProcessId
            self.responseReceived = responseReceived
        }
    }

    private final class PendingProcessTermination: @unchecked Sendable {
        let pid: UInt16
        let continuation: CheckedContinuation<SystemProcessResult, Error>

        init(pid: UInt16, continuation: CheckedContinuation<SystemProcessResult, Error>) {
            self.pid = pid
            self.continuation = continuation
        }
    }

    private func sendProcessCommand(
        _ payload: [UInt8],
        timeoutSeconds: TimeInterval = 3,
        spawnedProcessId: UInt8? = nil,
        destinationPid: UInt16 = 0
    ) async throws -> UInt16? {
        await processCommandGate.lock()
        do {
            let pid = try await sendProcessCommandLocked(
                payload,
                timeoutSeconds: timeoutSeconds,
                spawnedProcessId: spawnedProcessId,
                destinationPid: destinationPid
            )
            await processCommandGate.unlock()
            return pid
        } catch {
            await processCommandGate.unlock()
            throw error
        }
    }

    private func sendProcessCommandLocked(
        _ payload: [UInt8],
        timeoutSeconds: TimeInterval,
        spawnedProcessId: UInt8?,
        destinationPid: UInt16
    ) async throws -> UInt16? {
        guard let aidlabSDK else {
            throw AidlabError(message: "Device is not connected")
        }
        guard let frameConfirmation = beginFrameConfirmation() else {
            throw AidlabError(message: "Previous BLE frame is not confirmed")
        }

        let expectsShellResponse = destinationPid == 0
        let waitsForLifecycle = expectsShellResponse || spawnedProcessId != nil
        let result: SystemProcessResult? = try await withCheckedThrowingContinuation { continuation in
            let waiter = PendingProcessCommand(
                continuation: continuation,
                spawnedProcessId: spawnedProcessId,
                responseReceived: !expectsShellResponse
            )

            if waitsForLifecycle {
                commandStateLock.lock()
                if pendingProcessCommand != nil {
                    commandStateLock.unlock()
                    let error = AidlabError(message: "Another process command is already pending")
                    completeFrameConfirmation(error: error)
                    continuation.resume(throwing: error)
                    return
                }
                pendingProcessCommand = waiter
                commandStateLock.unlock()
            }

            var bytes = payload
            guard emitTrackedFrame({
                if expectsShellResponse {
                    AidlabSDK_send(&bytes, Int32(bytes.count), 0, aidlabSDK)
                } else {
                    AidlabSDK_send_process_command(
                        &bytes,
                        Int32(bytes.count),
                        Int32(destinationPid),
                        aidlabSDK
                    )
                }
            }) else {
                let error = AidlabError(message: "SDK rejected the BLE frame")
                if waitsForLifecycle {
                    completePendingProcessCommand(.failure(error), waiter: waiter)
                } else {
                    continuation.resume(throwing: error)
                }
                failFrameTransmission(error)
                return
            }

            if waitsForLifecycle {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self, weak waiter] in
                    guard let self, let waiter else { return }
                    completePendingProcessCommand(
                        .failure(AidlabError(message: "Timed out waiting for process command result")),
                        waiter: waiter
                    )
                }
            } else {
                continuation.resume(returning: nil)
            }
        }

        try await frameConfirmation.wait()
        if !expectsShellResponse {
            return destinationPid
        }
        guard let result else { return nil }
        return result.accepted ? result.pid : nil
    }

    private func sendActiveProcessCommand(
        _ payload: [UInt8],
        pid: UInt16,
        timeoutSeconds: TimeInterval = 3
    ) async throws -> UInt16? {
        await processCommandGate.lock()
        do {
            guard let aidlabSDK else {
                throw AidlabError(message: "Device is not connected")
            }
            guard let frameConfirmation = beginFrameConfirmation() else {
                throw AidlabError(message: "Previous BLE frame is not confirmed")
            }
            let result: SystemProcessResult = try await withCheckedThrowingContinuation { continuation in
                let waiter = PendingProcessTermination(pid: pid, continuation: continuation)

                commandStateLock.lock()
                if pendingProcessTermination != nil {
                    commandStateLock.unlock()
                    let error = AidlabError(message: "Another process termination is pending")
                    completeFrameConfirmation(error: error)
                    continuation.resume(throwing: error)
                    return
                }
                pendingProcessTermination = waiter
                commandStateLock.unlock()

                var bytes = payload
                guard emitTrackedFrame({
                    AidlabSDK_send_process_command(&bytes, Int32(bytes.count), Int32(pid), aidlabSDK)
                }) else {
                    let error = AidlabError(message: "SDK rejected the BLE frame")
                    completePendingProcessTermination(.failure(error), waiter: waiter)
                    failFrameTransmission(error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self, weak waiter] in
                    guard let self, let waiter else { return }
                    completePendingProcessTermination(
                        .failure(AidlabError(message: "Timed out waiting for process termination")),
                        waiter: waiter
                    )
                }
            }
            try await frameConfirmation.wait()
            await processCommandGate.unlock()
            return result.status == Device.systemKillSuccess ? pid : nil
        } catch {
            await processCommandGate.unlock()
            throw error
        }
    }

    private func completePendingProcessCommand(
        _ result: Result<SystemProcessResult?, Error>,
        waiter expectedWaiter: PendingProcessCommand? = nil
    ) {
        commandStateLock.lock()
        guard let waiter = pendingProcessCommand else {
            commandStateLock.unlock()
            return
        }
        if let expectedWaiter, waiter !== expectedWaiter {
            commandStateLock.unlock()
            return
        }
        pendingProcessCommand = nil
        commandStateLock.unlock()

        switch result {
        case let .success(value):
            waiter.continuation.resume(returning: value)
        case let .failure(error):
            waiter.continuation.resume(throwing: error)
        }
    }

    private func completePendingProcessTermination(
        _ result: Result<SystemProcessResult, Error>,
        waiter expectedWaiter: PendingProcessTermination? = nil
    ) {
        commandStateLock.lock()
        guard let waiter = pendingProcessTermination else {
            commandStateLock.unlock()
            return
        }
        if let expectedWaiter, waiter !== expectedWaiter {
            commandStateLock.unlock()
            return
        }
        pendingProcessTermination = nil
        commandStateLock.unlock()

        switch result {
        case let .success(value): waiter.continuation.resume(returning: value)
        case let .failure(error): waiter.continuation.resume(throwing: error)
        }
    }

    private func handleProcessCommandPayload(process: String, payload: Data) {
        guard let result = parseSystemProcessInformation(process: process, payload: payload) else {
            return
        }
        var commandCompletion: (PendingProcessCommand, Result<SystemProcessResult?, Error>)?
        commandStateLock.lock()
        updateActiveProcessPids(result)
        let terminationWaiter = pendingProcessTermination
        if result.status == Device.systemCreateSuccess || result.status == Device.systemCreateFailure,
           let waiter = pendingProcessCommand {
            if !waiter.responseReceived {
                waiter.responseReceived = true
                waiter.response = result
                if !result.accepted || waiter.spawnedProcessId == nil {
                    pendingProcessCommand = nil
                    commandCompletion = (waiter, .success(result))
                }
            } else if result.status == Device.systemCreateFailure || result.processId == waiter.spawnedProcessId {
                pendingProcessCommand = nil
                if result.accepted {
                    commandCompletion = (waiter, .success(waiter.response))
                } else {
                    commandCompletion = (
                        waiter,
                        .failure(AidlabError(message: "Firmware rejected required spawned process"))
                    )
                }
            }
        }
        commandStateLock.unlock()

        if let (waiter, completion) = commandCompletion {
            switch completion {
            case let .success(value): waiter.continuation.resume(returning: value)
            case let .failure(error): waiter.continuation.resume(throwing: error)
            }
        } else if terminationWaiter?.pid == result.pid {
            completePendingProcessTermination(.success(result), waiter: terminationWaiter)
        }
        if result.status == Device.systemKillSuccess {
            deviceDelegate?.processDidTerminate(self, pid: result.pid)
        }
    }

    private func updateActiveProcessPids(_ result: SystemProcessResult) {
        guard let processId = result.processId else { return }
        if result.status == Device.systemCreateSuccess {
            activeProcessPids[processId] = result.pid
        } else if result.status == Device.systemKillSuccess, activeProcessPids[processId] == result.pid {
            activeProcessPids.removeValue(forKey: processId)
        }
    }

    private func activePid(for processId: UInt8) -> UInt16? {
        commandStateLock.lock()
        defer { commandStateLock.unlock() }
        return activeProcessPids[processId]
    }

    private func parseSystemProcessInformation(process: String, payload: Data) -> SystemProcessResult? {
        guard process.caseInsensitiveCompare("system") == .orderedSame,
              let status = payload.first,
              status <= Device.systemKillFailure
        else {
            return nil
        }

        let bytes = [UInt8](payload)
        let pid: UInt16 = if bytes.count >= 3 {
            UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        } else {
            0
        }

        let processId = bytes.count >= 4 ? bytes[3] : nil
        return SystemProcessResult(status: status, pid: pid, processId: processId)
    }

    private func startLegacyCollection(dataTypes: [DataType]) {
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

    private func stopLegacyCollection() {
        for uuid in legacyCollectionNotificationUUIDs {
            transport.stopNotifications(uuid)
            activeNotificationUUIDs.remove(uuid)
        }
        legacyCollectionNotificationUUIDs.removeAll(keepingCapacity: false)
    }

    private func processCommandChunk(_ data: Data) {
        guard let aidlabSDK else { return }
        var scratchVal = [UInt8](data)
        AidlabSDK_process_ble_chunk(&scratchVal, Int32(scratchVal.count), aidlabSDK)
    }

    private func processBatteryPacket(_ data: Data) {
        guard aidlabSDK != nil else { return }
        var scratchVal = [UInt8](data)
        AidlabSDK_process_battery_package(&scratchVal, Int32(scratchVal.count), aidlabSDK)
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

    func drainChunkQueue() {
        guard readyForNextChunk else { return }
        guard !chunkQueue.isEmpty else { return }

        let chunk = chunkQueue.removeFirst()
        readyForNextChunk = false
        transport.writeCharacteristic(
            cmdCharacteristicUUID,
            data: chunk.data,
            withResponse: !usesV4Protocol()
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                handleCommandWriteResult(error: nil, completesFrame: chunk.completesFrame)
            case let .failure(error):
                handleCommandWriteResult(error: error, completesFrame: chunk.completesFrame)
            }
        }
    }

    func handleCommandWriteResult(error: Error?, completesFrame: Bool) {
        if let error {
            failFrameTransmission(AidlabError.wrapping(error))
            return
        }

        if completesFrame {
            armFrameConfirmationDeadline()
        }
        readyForNextChunk = true
        drainChunkQueue()
    }

    // -- AidlabSDK callback handlers ------------------------------------------

    // BLE Communication callbacks
    private let bleSendCallback: callbackBLESend = { context, data, size in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        let dataArray = Array(UnsafeBufferPointer(start: data, count: Int(size)))
        let completesFrame = self_.consumeTrackedFrameCallback()
        self_.sendRawBleData(dataArray, completesFrame: completesFrame)
    }

    private let bleReadyCallback: callbackBLEReady = { context in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.completeFrameConfirmation()
    }

    private let didReceiveECG: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveECG(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveRespiration: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRespiration(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveSkinTemperature: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSkinTemperature(self_, timestamp: timestamp, value: value)
    }

    private let didReceiveAccelerometer: callbackAccelerometer = { context, timestamp, ax, ay, az in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveAccelerometer(self_, timestamp: timestamp, ax: ax, ay: ay, az: az)
    }

    private let didReceiveGyroscope: callbackGyroscope = { context, timestamp, gx, gy, gz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveGyroscope(self_, timestamp: timestamp, gx: gx, gy: gy, gz: gz)
    }

    private let didReceiveMagnetometer: callbackMagnetometer = { context, timestamp, mx, my, mz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveMagnetometer(self_, timestamp: timestamp, mx: mx, my: my, mz: mz)
    }

    private let didReceiveQuaternion: callbackQuaternion = { context, timestamp, qw, qx, qy, qz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveQuaternion(self_, timestamp: timestamp, qw: qw, qx: qx, qy: qy, qz: qz)
    }

    private let didReceiveOrientation: callbackOrientation = { context, timestamp, roll, pitch, yaw in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveOrientation(self_, timestamp: timestamp, roll: roll, pitch: pitch, yaw: yaw)
    }

    private let didReceiveEDA: callbackEda = { context, timestamp, conductance in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveEDA(self_, timestamp: timestamp, conductance: conductance)
    }

    private let didReceiveGPS: callbackGps = { context, timestamp, latitude, longitude, altitude, speed, heading, hdop in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveGPS(self_,
                                            timestamp: timestamp,
                                            latitude: Double(latitude),
                                            longitude: Double(longitude),
                                            altitude: Double(altitude),
                                            speed: speed,
                                            heading: heading,
                                            hdop: hdop)
    }

    private let didReceiveBodyPosition: callbackBodyPosition = { context, timestamp, bodyPosition in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveBodyPosition(self_, timestamp: timestamp, bodyPosition: BodyPosition(bodyPosition: bodyPosition))
    }

    private let didReceiveHeartRate: callbackHeartRate = { context, timestamp, heartRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveHeartRate(self_, timestamp: timestamp, heartRate: heartRate)
    }

    private let didReceiveRr: callbackRr = { context, timestamp, rr in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRr(self_, timestamp: timestamp, rr: rr)
    }

    private let didReceiveRespirationRate: callbackRespirationRate = { context, timestamp, respirationRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveRespirationRate(self_, timestamp: timestamp, value: respirationRate)
    }

    private let wearStateDidChange: callbackWearState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.wearStateDidChange(self_, wearState: WearState(wearState: state))
    }

    private let didReceiveSoundVolume: callbackSoundVolume = { context, timestamp, soundVolume in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSoundVolume(self_, timestamp: timestamp, soundVolume: soundVolume)
    }

    private let didReceivePressure: callbackPressure = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePressure(self_, timestamp: timestamp, value: value)
    }

    private let pressureWearStateDidChange: callbackWearState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.pressureWearStateDidChange(self_, wearState: WearState(wearState: state))
    }

    private let didDetect: callback_function = { context, exercise in
        guard let context else { return }
        if exercise == AidlabSDK.exerciseNone { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectExercise(self_, exercise: Exercise(exercise: exercise))
    }

    private let didDetectActivity: callbackActivity = { context, timestamp, activity in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveActivity(self_, timestamp: timestamp, activity: ActivityType(activityType: activity))
    }

    private let didReceivePayload: callbackPayload = { context, process, payload, payloadLength, options in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        let processString = process.map { String(cString: $0) } ?? "unknown"

        let rawPayload = if let payload, payloadLength > 0 {
            Data(bytes: payload, count: Int(payloadLength))
        } else {
            Data()
        }

        self_.handleProcessCommandPayload(process: processString, payload: rawPayload)
        self_.deviceDelegate?.didReceivePayload(self_, process: processString, payload: rawPayload, options: options)
    }

    private let didReceiveProcessError: callbackProcessError = { context, process, pid, payload, payloadLength, options in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        let processString = process.map { String(cString: $0) } ?? "unknown"
        let rawPayload = if let payload, payloadLength > 0 {
            Data(bytes: payload, count: Int(payloadLength))
        } else {
            Data()
        }
        self_.deviceDelegate?.didReceiveProcessError(
            self_, process: processString, pid: pid, payload: rawPayload, options: options
        )
    }

    private let didDetectUserEvent: callbackUserEvent = { context, timestamp in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectUserEvent(self_, timestamp: timestamp)
    }

    private let didReceiveError: callbackError = { context, code, text in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()

        guard let cStringPointer = text,
              let string = String(validatingCString: cStringPointer)
        else { return }

        let error = AidlabError.fromCore(rawCode: Int32(code.rawValue), message: string)
        self_.completeFrameConfirmation(error: error)
        self_.deviceDelegate?.didReceiveError(self_, error: error)
    }

    private let didReceiveSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSignalQuality(self_, timestamp: timestamp, value: Int32(value))
    }

    private let didReceiveBatteryLevel: callbackBatteryLevel = { context, stateOfCharge in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveBatteryLevel(self_, stateOfCharge: stateOfCharge)
    }

    private let didReceiveSteps: callbackSteps = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSteps(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastECG: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastECG(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastRespiration: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRespiration(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastSkinTemperature: callbackSampleTime = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSkinTemperature(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastHeartRate: callbackHeartRate = { context, timestamp, heartRate in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastHeartRate(self_, timestamp: timestamp, heartRate: heartRate)
    }

    private let syncStateDidChange: callbackSyncState = { context, state in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.syncStateDidChange(self_, state: SyncState(syncState: state))
    }

    private let didReceiveUnsynchronizedSize: callbackUnsynchronizedSize = { context, unsynchronizedSize, syncBytesPerSecond in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveUnsynchronizedSize(self_, unsynchronizedSize: unsynchronizedSize, syncBytesPerSecond: syncBytesPerSecond)
    }

    private let didReceivePastRespirationRate: callbackRespirationRate = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRespirationRate(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastActivity: callbackActivity = { context, timestamp, activity in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastActivity(self_, timestamp: timestamp, activity: ActivityType(activityType: activity))
    }

    private let didReceivePastSteps: callbackSteps = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSteps(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastRr: callbackRr = { context, timestamp, rr in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastRr(self_, timestamp: timestamp, rr: rr)
    }

    private let didReceivePastSoundVolume: callbackSoundVolume = { context, timestamp, soundVolume in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSoundVolume(self_, timestamp: timestamp, soundVolume: soundVolume)
    }

    private let didReceivePastPressure: callbackPressure = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastPressure(self_, timestamp: timestamp, value: value)
    }

    private let didReceivePastAccelerometer: callbackAccelerometer = { context, timestamp, ax, ay, az in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastAccelerometer(self_, timestamp: timestamp, ax: ax, ay: ay, az: az)
    }

    private let didReceivePastGyroscope: callbackGyroscope = { context, timestamp, gx, gy, gz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastGyroscope(self_, timestamp: timestamp, gx: gx, gy: gy, gz: gz)
    }

    private let didReceivePastQuaternion: callbackQuaternion = { context, timestamp, qw, qx, qy, qz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastQuaternion(self_, timestamp: timestamp, qw: qw, qx: qx, qy: qy, qz: qz)
    }

    private let didReceivePastOrientation: callbackOrientation = { context, timestamp, roll, pitch, yaw in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastOrientation(self_, timestamp: timestamp, roll: roll, pitch: pitch, yaw: yaw)
    }

    private let didReceivePastEDA: callbackEda = { context, timestamp, conductance in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastEDA(self_, timestamp: timestamp, conductance: conductance)
    }

    private let didReceivePastGPS: callbackGps = { context, timestamp, latitude, longitude, altitude, speed, heading, hdop in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastGPS(self_,
                                                timestamp: timestamp,
                                                latitude: Double(latitude),
                                                longitude: Double(longitude),
                                                altitude: Double(altitude),
                                                speed: speed,
                                                heading: heading,
                                                hdop: hdop)
    }

    private let didReceivePastMagnetometer: callbackMagnetometer = { context, timestamp, mx, my, mz in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastMagnetometer(self_, timestamp: timestamp, mx: mx, my: my, mz: mz)
    }

    private let didReceivePastBodyPosition: callbackBodyPosition = { context, timestamp, bodyPosition in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastBodyPosition(self_, timestamp: timestamp, bodyPosition: BodyPosition(bodyPosition: bodyPosition))
    }

    private let didDetectPastUserEvent: callbackUserEvent = { context, timestamp in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didDetectPastUserEvent(self_, timestamp: timestamp)
    }

    private let didReceivePastSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceivePastSignalQuality(self_, timestamp: timestamp, value: UInt8(value))
    }
}
