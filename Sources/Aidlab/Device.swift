//
//  Created by J Domaszewicz on 10.11.2016.
//  Copyright © 2016-2024 Aidlab. All rights reserved.
//

import AidlabSDK
@preconcurrency import CoreBluetooth
import Foundation

final class FrameConfirmation: @unchecked Sendable {
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

/// Device state and its C core live on the main queue; public methods may be called from any thread.
func onMainQueue(_ work: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async(execute: work)
    }
}

actor ProcessCommandGate {
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

/// An Aidlab or Aidmed One.
///
/// Commands (``collect(dataTypes:dataTypesToStore:)``, ``stopCollect()``, ``startSynchronization()``,
/// ``stopSynchronization()``, ``clearSynchronization()``) return the PID of the device process that handles them, or
/// `nil` when no process does. They throw ``AidlabError`` when the device refuses or rejects the command, the link
/// fails or the device does not answer in time.
public class Device: NSObject, @unchecked Sendable {
    private static let systemCreateSuccess: UInt8 = 0
    private static let systemCreateFailure: UInt8 = 1
    private static let systemKillSuccess: UInt8 = 2
    private static let systemKillFailure: UInt8 = 3
    static let syncProcessId: UInt8 = 7
    private static let collectProcessId: UInt8 = 8
    private static let frameConfirmationTimeout: TimeInterval = 3
    private static let legacyCommandReceived = Data("RECEIVED".utf8)

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
    var activeNotificationUUIDs: Set<CBUUID> = []
    var legacyCollectionNotificationUUIDs: Set<CBUUID> = []
    private var didHandleDisconnect = false
    /// Reason for a disconnect that the SDK started; the transport reports it as an app disconnect.
    private var resetReason: DisconnectReason?
    let processCommandGate = ProcessCommandGate()
    private var pendingProcessCommand: PendingProcessCommand?
    private var pendingProcessTermination: PendingProcessTermination?
    private var activeProcessPids: [UInt8: UInt16] = [:]
    var legacyCommandConfirmation: FrameConfirmation?
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
                let value = rssi.int32Value
                onMainQueue { self.deviceDelegate?.didUpdateRSSI(self, rssi: value) }
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

    deinit {
        if let aidlabSDK {
            Device.release(aidlabSDK)
        }
    }

    public func connect(delegate: DeviceDelegate) {
        nonisolated(unsafe) let delegate = delegate
        onMainQueue { [self] in
            deviceDelegate = delegate
            resetBleQueue()
            didHandleDisconnect = false
            resetReason = nil
            stopAllNotifications()

            transport.onDisconnect = { [weak self] reason, error in
                guard let self else { return }
                onMainQueue {
                    if let error {
                        self.deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
                    }
                    self.handleDisconnected(reason: reason)
                }
            }

            transport.connect { [weak self] result in
                guard let self else { return }
                onMainQueue {
                    switch result {
                    case .success:
                        self.onTransportConnected()
                    case let .failure(error):
                        self.deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
                    }
                }
            }
        }
    }

    public func disconnect() {
        onMainQueue { [self] in
            resetBleQueue()
            transport.disconnect()
        }
    }

    /// Configures live and autonomous collection. Returns the collect PID, or `nil` on firmware before 3.6.0.
    @MainActor
    public func collect(dataTypes: [DataType], dataTypesToStore: [DataType]) async throws -> UInt16? {
        guard aidlabSDK != nil else {
            throw AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API.")
        }

        guard let firmwareSemantic = firmwareVersion else {
            throw AidlabError(message: "API misuse: Attempt to use the API without an established connection. Please ensure the device is connected using the connect() method before invoking this API.")
        }

        if !isLegacyFirmware() {
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
                    startedProcessId: Device.collectProcessId,
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
                return try await sendProcessCommand(
                    buffer,
                    startedProcessId: Device.collectProcessId,
                    destinationPid: activeCollectPid ?? 0
                )
            }

        } else { /// Legacy
            try await configureLegacyStorage(dataTypesToStore)
            startLegacyCollection(dataTypes: dataTypes)
            return nil
        }
    }

    public func readRSSI() {
        onMainQueue { [self] in
            guard let peripheral else {
                deviceDelegate?.didReceiveError(self, error: AidlabError(message: "RSSI not available for this transport"))
                return
            }
            peripheral.readRSSI()
        }
    }

    /// Starts sending stored data. Returns the sync PID, or `nil` on firmware before 2.2.18.
    @MainActor
    public func startSynchronization() async throws -> UInt16? {
        try await sendProcessCommand(commandBytes(synchronizationStartCommand()), startedProcessId: Device.syncProcessId)
    }

    /// Stops sending stored data. Returns the PID of the stopped sync process, or `nil` when no synchronization runs
    /// or on firmware before 2.2.18.
    @MainActor
    public func stopSynchronization() async throws -> UInt16? {
        if !hasProcesses() {
            return try await sendProcessCommand(commandBytes("sync stop"))
        }
        let activePid = activePid(for: Device.syncProcessId)
        if let activePid {
            return try await sendActiveProcessCommand(commandBytes("sync stop"), pid: activePid)
        }
        return nil
    }

    /// Clears data stored for synchronization. Returns the PID, or `nil` on firmware before 2.2.18.
    @MainActor
    public func clearSynchronization() async throws -> UInt16? {
        try await sendProcessCommand(commandBytes("sync clear"), startedProcessId: Device.syncProcessId)
    }

    /// Stops live streaming without changing autonomous storage. Returns the collect PID, or `nil` on firmware
    /// before 3.6.0.
    @MainActor
    public func stopCollect() async throws -> UInt16? {
        guard firmwareVersion != nil else {
            throw AidlabError(message: "Firmware revision is unavailable")
        }
        if isLegacyFirmware() {
            stopLegacyCollection()
            return nil
        }
        guard let collectPid = activePid(for: Device.collectProcessId) else {
            // A reconnect forgets the PIDs while the device keeps collecting; the shell finds the process.
            return try await sendProcessCommand(commandBytes("collect off"), startedProcessId: Device.collectProcessId)
        }
        return try await sendProcessCommand(commandBytes("collect off"), destinationPid: collectPid)
    }

    /// Sets the device clock to a Unix timestamp in seconds; throws when the write fails.
    @MainActor
    public func setTime(_ timestamp: UInt32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeTime(timestamp) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Sends a raw payload to a runtime destination PID and returns once the device has it. Use processId 0 for
    /// shell/system commands. Payloads go out in call order, each after the command in flight. Throws when the
    /// payload does not reach the device; the process lifecycle arrives through the delegate.
    @MainActor
    public func send(_ bytes: [UInt8], processId: Int = 0) async throws {
        guard !bytes.isEmpty else { return }
        guard let pid = UInt16(exactly: processId) else {
            throw AidlabError(message: "Invalid process ID \(processId)")
        }
        _ = try await sendProcessCommand(bytes, destinationPid: pid, raw: true)
    }

    private func writeTime(_ timestamp: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        let payload = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
        transport.writeCharacteristic(
            CurrentTimeService.currentTimeCharacteristic,
            data: payload,
            withResponse: true,
            completion: completion
        )
    }

    // -- Internal -------------------------------------------------------------

    // Avoid implicitly unwrapped optional; use optional and guard when needed
    var aidlabSDK: UnsafeMutableRawPointer?
    var deviceDelegate: DeviceDelegate?

    var maxCmdPackageLength: Int = 20

    // BLE transport state
    private var chunkQueue: [QueuedBLEChunk] = []
    var readyForNextChunk: Bool = true
    private var awaitingFrameConfirmation = false
    private var frameConfirmationGeneration: UInt64 = 0
    private var frameConfirmationDeadline: DispatchWorkItem?
    private var currentFrameConfirmation: FrameConfirmation?
    /// Set while a core send runs; cleared when the core emits the frame.
    private var awaitsTrackedFrame = false

    func startNotify(
        uuid: CBUUID,
        required: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        activeNotificationUUIDs.insert(uuid)
        transport.startNotifications(
            uuid,
            onData: { data in onMainQueue { onData(data) } },
            onError: { [weak self] error in
                guard let self, required else { return }
                onMainQueue {
                    self.deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error))
                    self.resetSession(.unknownError)
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
        legacyCommandConfirmation?.finish(.failure(AidlabError(message: "Device disconnected")))
        activeProcessPids.removeAll()

        let resolvedReason = resetReason ?? reason
        resetReason = nil

        stopAllNotifications()
        resetBleQueue()

        if let aidlabSDK {
            Device.release(aidlabSDK)
        }
        aidlabSDK = nil

        // Clear the session first so that a reconnect from didDisconnect keeps its delegate.
        let delegate = deviceDelegate
        deviceDelegate = nil
        transport.onDisconnect = nil
        delegate?.didDisconnect(self, reason: resolvedReason)
    }

    /// Detaches the core from its device and destroys it once the core call on the stack, if any, returns.
    private static func release(_ sdk: UnsafeMutableRawPointer) {
        AidlabSDK_set_error_callback(nil, nil, sdk)
        AidlabSDK_set_context(nil, sdk)
        nonisolated(unsafe) let core = sdk
        DispatchQueue.main.async { AidlabSDK_destroy(core) }
    }

    private func readConnectionMetadata(completion: @escaping @Sendable () -> Void) {
        @Sendable func readUtf8(_ uuid: CBUUID, completion: @escaping @Sendable (String?) -> Void) {
            transport.readCharacteristic(uuid) { result in
                let text = (try? result.get()).flatMap { String(bytes: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\0", with: "")
                let value = text?.isEmpty == false ? text : nil
                onMainQueue { completion(value) }
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
                            resetSession(.unknownError)
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
        // The firmware needs the clock to timestamp and store sessions; before 2.2.2 it has no clock service.
        if hasClockService() {
            writeTime(UInt32(Date().timeIntervalSince1970)) { [weak self] result in
                guard let self, case let .failure(error) = result else { return }
                onMainQueue { self.deviceDelegate?.didReceiveError(self, error: AidlabError.wrapping(error)) }
            }
        }

        guard createAidlabSDK() else {
            resetSession(.unknownError)
            return
        }

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
            // Firmware before 3.6.0 reports the battery on its own characteristic.
            uuid: isLegacyFirmware() ? batteryCharacteristicUUID : BatteryLevelService.batteryLevelCharacteristic,
            required: false,
            onData: { [weak self] data in
                self?.processBatteryPacket(data)
            }
        )

        /// Users are notified about the connection after reading the firmware revision
        deviceDelegate?.didConnect(self)
    }

    func createAidlabSDK() -> Bool {
        guard let firmwareRevision else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Missing firmware revision"))
            return false
        }

        var fwVersion: [UInt8] = Array(firmwareRevision.utf8)
        aidlabSDK = AidlabSDK_create(&fwVersion, Int32(fwVersion.count))
        resetBleQueue()

        guard let aidlabSDK else {
            deviceDelegate?.didReceiveError(self, error: AidlabError(message: "Unsupported firmware revision \(firmwareRevision)"))
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AidlabSDK_set_context(context, aidlabSDK)
        AidlabSDK_set_error_callback(didReceiveError, context, aidlabSDK)

        AidlabSDK_set_ble_send_callback(bleSendCallback, aidlabSDK)
        AidlabSDK_set_ble_ready_callback(bleReadyCallback, aidlabSDK)
        AidlabSDK_set_ble_frame_result_callback(bleFrameResultCallback, aidlabSDK)

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
        return true
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
        guard !awaitingFrameConfirmation else { return nil }
        let confirmation = FrameConfirmation()
        awaitingFrameConfirmation = true
        currentFrameConfirmation = confirmation
        frameConfirmationGeneration &+= 1
        frameConfirmationDeadline?.cancel()
        frameConfirmationDeadline = nil
        return confirmation
    }

    /// Runs a core send and reports whether the core emitted a frame for it.
    private func emitTrackedFrame(_ action: () -> Void) -> Bool {
        awaitsTrackedFrame = true
        action()
        let emitted = !awaitsTrackedFrame
        awaitsTrackedFrame = false
        return emitted
    }

    private func consumeTrackedFrameCallback() -> Bool {
        let tracked = awaitsTrackedFrame
        awaitsTrackedFrame = false
        return tracked
    }

    private func armFrameConfirmationDeadline() {
        if !usesV4Protocol() {
            completeFrameConfirmation()
            return
        }
        guard awaitingFrameConfirmation else { return }

        frameConfirmationGeneration &+= 1
        let generation = frameConfirmationGeneration
        frameConfirmationDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            self?.frameConfirmationDidTimeout(generation: generation)
        }
        frameConfirmationDeadline = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Device.frameConfirmationTimeout,
            execute: deadline
        )
    }

    private func completeFrameConfirmation(error: Error? = nil) {
        awaitingFrameConfirmation = false
        frameConfirmationGeneration &+= 1
        frameConfirmationDeadline?.cancel()
        frameConfirmationDeadline = nil
        let confirmation = currentFrameConfirmation
        currentFrameConfirmation = nil
        awaitsTrackedFrame = false
        if let error {
            confirmation?.finish(.failure(error))
        } else {
            confirmation?.finish(.success(()))
        }
    }

    private func failFrameTransmission(_ error: AidlabError, reason: DisconnectReason = .unknownError) {
        chunkQueue.removeAll(keepingCapacity: false)
        readyForNextChunk = true
        rejectFrame(error)
        deviceDelegate?.didReceiveError(self, error: error)
        resetSession(reason)
    }

    /// Ends a session that the SDK cannot continue, so that didDisconnect reports why.
    private func resetSession(_ reason: DisconnectReason) {
        resetReason = reason
        transport.disconnect()
    }

    /// Fails the frame in flight and the command that waits for it.
    private func rejectFrame(_ error: AidlabError) {
        refuseFrame(error)
        completePendingProcessTermination(.failure(error))
    }

    /// Fails a frame that the device refused. A process that ends before the frame reaches it refuses the frame, so
    /// its termination still answers a command addressed to it.
    private func refuseFrame(_ error: AidlabError) {
        completeFrameConfirmation(error: error)
        completePendingProcessCommand(.failure(error))
    }

    private func frameConfirmationDidTimeout(generation: UInt64) {
        guard awaitingFrameConfirmation, frameConfirmationGeneration == generation else { return }
        failFrameTransmission(AidlabError(code: .transport, message: "BLE frame confirmation timed out"), reason: .timeout)
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
        let startedProcessId: UInt8?
        let spawnedProcessId: UInt8?
        var responseReceived: Bool
        var response: SystemProcessResult?

        init(
            continuation: CheckedContinuation<SystemProcessResult?, Error>,
            startedProcessId: UInt8?,
            spawnedProcessId: UInt8?,
            responseReceived: Bool
        ) {
            self.continuation = continuation
            self.startedProcessId = startedProcessId
            self.spawnedProcessId = spawnedProcessId
            self.responseReceived = responseReceived
        }

        /// Whether a create lifecycle belongs to this command rather than to a raw payload sent before it.
        func answers(_ result: SystemProcessResult) -> Bool {
            // A shell-level create_failure names no process.
            guard let startedProcessId, let processId = result.processId else { return true }
            return processId == startedProcessId
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

    @MainActor
    func sendProcessCommand(
        _ payload: [UInt8],
        timeoutSeconds: TimeInterval = 6,
        startedProcessId: UInt8? = nil,
        spawnedProcessId: UInt8? = nil,
        destinationPid: UInt16 = 0,
        raw: Bool = false
    ) async throws -> UInt16? {
        await processCommandGate.lock()
        do {
            let pid = try await sendProcessCommandLocked(
                payload,
                timeoutSeconds: timeoutSeconds,
                startedProcessId: startedProcessId,
                spawnedProcessId: spawnedProcessId,
                destinationPid: destinationPid,
                raw: raw
            )
            await processCommandGate.unlock()
            return pid
        } catch {
            await processCommandGate.unlock()
            throw error
        }
    }

    @MainActor
    func sendProcessCommandLocked(
        _ payload: [UInt8],
        timeoutSeconds: TimeInterval,
        startedProcessId: UInt8?,
        spawnedProcessId: UInt8?,
        destinationPid: UInt16,
        raw: Bool
    ) async throws -> UInt16? {
        guard let aidlabSDK else {
            throw AidlabError(message: "Device is not connected")
        }
        guard let frameConfirmation = beginFrameConfirmation() else {
            throw AidlabError(message: "Previous BLE frame is not confirmed")
        }

        // Firmware before 2.2.18 answers commands without a process lifecycle. A raw payload leaves the lifecycle to
        // the delegate: a builtin such as kill or a control byte starts no process.
        let expectsShellResponse = destinationPid == 0 && !raw && hasProcesses()
        let waitsForLifecycle = expectsShellResponse || spawnedProcessId != nil
        let result: SystemProcessResult? = try await withCheckedThrowingContinuation { continuation in
            let waiter = PendingProcessCommand(
                continuation: continuation,
                startedProcessId: startedProcessId,
                spawnedProcessId: spawnedProcessId,
                responseReceived: !expectsShellResponse
            )

            if waitsForLifecycle {
                if pendingProcessCommand != nil {
                    let error = AidlabError(message: "Another process command is already pending")
                    completeFrameConfirmation(error: error)
                    continuation.resume(throwing: error)
                    return
                }
                pendingProcessCommand = waiter
            }

            var bytes = payload
            guard emitTrackedFrame({
                if destinationPid == 0 || raw {
                    AidlabSDK_send(&bytes, Int32(bytes.count), Int32(destinationPid), aidlabSDK)
                } else {
                    AidlabSDK_send_process_command(
                        &bytes,
                        Int32(bytes.count),
                        Int32(destinationPid),
                        aidlabSDK
                    )
                }
            }) else {
                // A local rejection fails only this command; the session remains usable.
                let error = AidlabError(message: "SDK rejected the BLE frame")
                completeFrameConfirmation(error: error)
                if waitsForLifecycle {
                    completePendingProcessCommand(.failure(error), waiter: waiter)
                } else {
                    continuation.resume(throwing: error)
                }
                return
            }

            if waitsForLifecycle {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self, weak waiter] in
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
        if destinationPid != 0 {
            return destinationPid
        }
        guard let result else { return nil }
        guard result.accepted else {
            throw AidlabError(message: "Device refused to start the process")
        }
        return result.pid
    }

    @MainActor
    private func sendActiveProcessCommand(
        _ payload: [UInt8],
        pid: UInt16,
        timeoutSeconds: TimeInterval = 6
    ) async throws -> UInt16? {
        await processCommandGate.lock()
        do {
            guard let aidlabSDK else {
                throw AidlabError(message: "Device is not connected")
            }
            guard let frameConfirmation = beginFrameConfirmation() else {
                throw AidlabError(message: "Previous BLE frame is not confirmed")
            }
            let result: SystemProcessResult
            do {
                result = try await withCheckedThrowingContinuation { continuation in
                    let waiter = PendingProcessTermination(pid: pid, continuation: continuation)

                    if pendingProcessTermination != nil {
                        let error = AidlabError(message: "Another process termination is pending")
                        completeFrameConfirmation(error: error)
                        continuation.resume(throwing: error)
                        return
                    }
                    pendingProcessTermination = waiter

                    var bytes = payload
                    guard emitTrackedFrame({
                        AidlabSDK_send_process_command(&bytes, Int32(bytes.count), Int32(pid), aidlabSDK)
                    }) else {
                        let error = AidlabError(message: "SDK rejected the BLE frame")
                        completeFrameConfirmation(error: error)
                        completePendingProcessTermination(.failure(error), waiter: waiter)
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self, weak waiter] in
                        guard let self, let waiter else { return }
                        completePendingProcessTermination(
                            .failure(AidlabError(message: "Timed out waiting for process termination")),
                            waiter: waiter
                        )
                    }
                }
            } catch {
                // A refused frame explains a missing termination better than the timeout.
                try await frameConfirmation.wait()
                throw error
            }
            do {
                try await frameConfirmation.wait()
            } catch {
                // A process that ends before the frame reaches it refuses the frame; its termination still answers
                // the command.
                guard result.status == Device.systemKillSuccess else { throw error }
            }
            await processCommandGate.unlock()
            if result.status == Device.systemKillSuccess {
                return pid
            }
        } catch {
            await processCommandGate.unlock()
            throw error
        }
        throw AidlabError(message: "Device refused to stop process \(pid)")
    }

    private func completePendingProcessCommand(
        _ result: Result<SystemProcessResult?, Error>,
        waiter expectedWaiter: PendingProcessCommand? = nil
    ) {
        guard let waiter = pendingProcessCommand else { return }
        if let expectedWaiter, waiter !== expectedWaiter { return }
        pendingProcessCommand = nil

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
        guard let waiter = pendingProcessTermination else { return }
        if let expectedWaiter, waiter !== expectedWaiter { return }
        pendingProcessTermination = nil

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
        updateActiveProcessPids(result)
        let terminationWaiter = pendingProcessTermination
        if result.status == Device.systemCreateSuccess || result.status == Device.systemCreateFailure,
           let waiter = pendingProcessCommand {
            if !waiter.responseReceived {
                if waiter.answers(result) {
                    waiter.responseReceived = true
                    waiter.response = result
                    if !result.accepted || waiter.spawnedProcessId == nil {
                        pendingProcessCommand = nil
                        commandCompletion = (waiter, .success(result))
                    }
                }
            } else if result.status == Device.systemCreateFailure || result.processId == waiter.spawnedProcessId {
                // Firmware 3.7.84-3.7.110 starts a sync with collect and refuses it while another sync runs; the
                // collect succeeded either way.
                pendingProcessCommand = nil
                commandCompletion = (waiter, .success(waiter.response))
            }
        }

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
        if result.status == Device.systemCreateSuccess, let processId = result.processId {
            activeProcessPids[processId] = result.pid
        } else if result.status == Device.systemKillSuccess {
            // Firmware before 3.7.113 reports an ended collect process with a wrong process ID; the PID is unique.
            activeProcessPids = activeProcessPids.filter { $0.value != result.pid }
        }
    }

    private func activePid(for processId: UInt8) -> UInt16? {
        activeProcessPids[processId]
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
            let completesFrame = chunk.completesFrame
            onMainQueue {
                switch result {
                case .success:
                    self.handleCommandWriteResult(error: nil, completesFrame: completesFrame)
                case let .failure(error):
                    self.handleCommandWriteResult(error: error, completesFrame: completesFrame)
                }
            }
        }
    }

    func handleCommandWriteResult(error: Error?, completesFrame: Bool) {
        if let error {
            failFrameTransmission(AidlabError(code: .transport, message: error.localizedDescription, underlyingError: error))
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

    private let bleFrameResultCallback: callbackBLEFrameResult = { context, result in
        guard let context, result != 0 else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.refuseFrame(AidlabError(message: "Device rejected the frame with NAK code \(result)"))
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
        if rawPayload == Device.legacyCommandReceived {
            self_.legacyCommandConfirmation?.finish(.success(()))
        }
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
        self_.deviceDelegate?.didReceiveError(self_, error: error)
        if error.code == .protocol {
            // The session is unreliable; reset it once the core call that reported the error returns.
            DispatchQueue.main.async { self_.resetSession(.unknownError) }
        }
    }

    private let didReceiveSignalQuality: callbackSignalQuality = { context, timestamp, value in
        guard let context else { return }
        let self_ = Unmanaged<Device>.fromOpaque(context).takeUnretainedValue()
        self_.deviceDelegate?.didReceiveSignalQuality(self_, timestamp: timestamp, value: value)
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
        self_.deviceDelegate?.didReceivePastSignalQuality(self_, timestamp: timestamp, value: value)
    }
}
