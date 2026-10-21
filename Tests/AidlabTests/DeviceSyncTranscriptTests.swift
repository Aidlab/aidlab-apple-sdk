//
//  Copyright © 2026 Aidlab. All rights reserved.
//

// Byte sequences the firmware sends around `sync stop` and `sync clear`, as its code writes them: Aidlab 1 at tag
// 3.7.115 (ProcessManager.cpp create_process/kill_process, Sync.cpp) and Aidlab 2 at firmware-esp32 5e1fd7a
// (process_manager.cpp sendLifecycle/finishAnswer, sync.cpp).

@testable import Aidlab
import CoreBluetooth
import XCTest

private let commandCharacteristic = CBUUID(string: "51366E80-CF3A-11E1-9AB4-0002A5D5C51B")

private let accepted: UInt8 = 0
private let rejected: UInt8 = 1
private let exited: UInt8 = 2
private let syncProcess: UInt8 = 7
private let syncStart: UInt64 = 0
private let syncStop: UInt64 = 1
private let syncEnd: UInt64 = 2
private let syncCount: UInt64 = 4

private func syncOptions(_ status: UInt64, _ value: UInt64 = 0) -> UInt64 {
    (status << 32) | value
}

/// A SystemProcessInformation payload for `pid` running process `processId`, with the reason of `rejected` or the
/// exit status of `exited` as `detail`.
private func lifecycle(_ status: UInt8, _ pid: UInt16, _ processId: UInt8, _ detail: UInt8? = nil) -> [UInt8] {
    [status, UInt8(pid & 0xFF), UInt8(pid >> 8), processId] + (detail.map { [$0] } ?? [])
}

private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

/// One frame as Aidlab 1 from 3.7.11x sends it (V3.1): a 20-byte header notification, then the payload in 20-byte
/// notifications whose padding the firmware does not clear.
private func v31(_ payload: [UInt8], pid: UInt16 = 0, options: UInt64 = 0) -> [[UInt8]] {
    var header = [1, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8), 0, UInt8(pid & 0xFF), UInt8(pid >> 8)]
    header += littleEndian(options)
    header += [UInt8](repeating: 0, count: 20 - header.count)
    let chunks = stride(from: 0, to: payload.count, by: 20).map { offset in
        (offset ..< offset + 20).map { $0 < payload.count ? payload[$0] : 0xEE }
    }
    return [header] + chunks
}

/// A device frame of the V4 protocol (firmware 4.x).
private func v4(_ payload: [UInt8], pid: UInt16, processType: UInt8, options: UInt64) -> [UInt8] {
    var header = [4, 0x0A, processType, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8),
                  UInt8(pid & 0xFF), UInt8(pid >> 8)]
    header += littleEndian(options)
    header += [UInt8](repeating: 0, count: 20 - header.count)
    return header + payload
}

/// Transport that records the command writes and replays device notifications; Aidlab 2 frames get their ACK.
private final class TranscriptTransport: AidlabTransport, @unchecked Sendable {
    let address = UUID()
    let name: String? = "Aidlab"
    var rssi: NSNumber = -50
    var mtuSize = 244
    var onDisconnect: ((DisconnectReason, Error?) -> Void)?

    let firmware: String
    private(set) var writes: [[UInt8]] = []
    private var notifications: [CBUUID: (Data) -> Void] = [:]

    init(firmware: String) {
        self.firmware = firmware
    }

    /// Text of the bytes written to the command characteristic, in order.
    var commandText: String {
        String(bytes: writes.joined(), encoding: .isoLatin1) ?? ""
    }

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { completion(.success(())) }
    }

    func disconnect() {
        DispatchQueue.main.async { self.onDisconnect?(.appDisconnected, nil) }
    }

    func readCharacteristic(_ uuid: CBUUID, completion: @escaping (Result<Data, Error>) -> Void) {
        let value = uuid.uuidString.uppercased() == "2A26" ? firmware : "Aidlab"
        DispatchQueue.main.async { completion(.success(Data(value.utf8))) }
    }

    func writeCharacteristic(_ uuid: CBUUID, data: Data, withResponse: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        if uuid == commandCharacteristic {
            let bytes = [UInt8](data)
            writes.append(bytes)
            if bytes.count >= 20, bytes[0] == 4, bytes[16] & 0x04 != 0 {
                notify([0x06])
            }
        }
        if withResponse {
            DispatchQueue.main.async { completion(.success(())) }
        } else {
            completion(.success(()))
        }
    }

    func startNotifications(_ uuid: CBUUID, onData: @escaping (Data) -> Void, onError _: @escaping (Error) -> Void) {
        notifications[uuid] = onData
    }

    func stopNotifications(_ uuid: CBUUID) {
        notifications.removeValue(forKey: uuid)
    }

    /// Sends a notification on the command characteristic, as CoreBluetooth does, on the main queue.
    func notify(_ bytes: [UInt8]) {
        DispatchQueue.main.async {
            self.notifications[commandCharacteristic]?(Data(bytes))
        }
    }

    /// Sends one device frame: V3.1 notifications on Aidlab 1, a V4 frame on Aidlab 2.
    func send(_ payload: [UInt8], pid: UInt16 = 0, options: UInt64 = 0) {
        if firmware.hasPrefix("4.") {
            notify(v4(payload, pid: pid, processType: pid == 0 ? 0 : syncProcess, options: options))
        } else {
            v31(payload, pid: pid, options: options).forEach(notify)
        }
    }
}

private final class TranscriptDelegate: DeviceDelegate, @unchecked Sendable {
    var exits: [(pid: UInt16, status: Int?)] = []
    var syncStates: [SyncState] = []

    func didConnect(_: Device) {}
    func didDisconnect(_: Device, reason _: DisconnectReason) {}
    func didReceiveError(_: Device, error _: AidlabError) {}

    func processDidExit(_: Device, pid: UInt16, exitStatus: Int?) {
        exits.append((pid, exitStatus))
    }

    func syncStateDidChange(_: Device, state: SyncState) {
        syncStates.append(state)
    }
}

private struct Session {
    let transport: TranscriptTransport
    let delegate: TranscriptDelegate
    let device: Device
}

@MainActor
final class DeviceSyncTranscriptTests: XCTestCase {
    // -- Aidlab 1 3.7.115 -----------------------------------------------------

    func testAidlab1StopEndsWithTheExitOfTheRunningSyncThenClearRuns() async throws {
        let session = try await startSync(firmware: "3.7.115", pid: 4)
        let (transport, delegate, device) = (session.transport, session.delegate, session.device)
        var stopped = false
        let stop = Task {
            defer { stopped = true }
            return try await device.stopSynchronization()
        }
        await waitUntil { transport.commandText.contains("sync stop") }
        let clear = Task { try await device.clearSynchronization() }

        // The slot's sync takes the stop: create_success, its SYNC_STOP, then kill_success once it ends.
        transport.send(lifecycle(accepted, 4, syncProcess))
        transport.send(Array("sync stop".utf8), pid: 4, options: syncOptions(syncStop))
        await waitUntil { delegate.syncStates.count == 2 }
        XCTAssertFalse(stopped)
        XCTAssertFalse(transport.commandText.contains("sync clear"))

        transport.send(lifecycle(exited, 4, syncProcess))
        let stoppedPid = try await stop.value
        XCTAssertEqual(stoppedPid, 4)
        await waitUntil { transport.commandText.contains("sync clear") }

        // The freed slot runs the clear, which ends without output.
        transport.send(lifecycle(accepted, 4, syncProcess))
        transport.send(lifecycle(exited, 4, syncProcess))
        let cleared = try await clear.value
        XCTAssertEqual(cleared, 4)
        await waitUntil { delegate.exits.count == 2 }
        XCTAssertEqual(delegate.syncStates, [.start, .stop])
        XCTAssertEqual(delegate.exits.map(\.pid), [4, 4])
        XCTAssertEqual(delegate.exits.map(\.status), [nil, nil])
    }

    func testAidlab1ClearDuringTheSyncGetsCreateFailure() async throws {
        let session = try await startSync(firmware: "3.7.115", pid: 4)
        let (transport, device) = (session.transport, session.device)
        let clear = Task { try await device.clearSynchronization() }
        await waitUntil { transport.commandText.contains("sync clear") }

        transport.send(lifecycle(rejected, 0, syncProcess))

        do {
            _ = try await clear.value
            XCTFail("create_failure must reject the clear")
        } catch let error as AidlabError {
            XCTAssertEqual(error.rejectionReason, .unknown)
        }
    }

    func testAidlab1SyncThatEndsBeforeItsStopLeavesTheStopToANewOne() async throws {
        let session = try await startSync(firmware: "3.7.115", pid: 4)
        let (transport, delegate, device) = (session.transport, session.delegate, session.device)
        let stop = Task { try await device.stopSynchronization() }
        await waitUntil { transport.commandText.contains("sync stop") }

        // The sync ran out of data while the stop was on its way; the stop then starts a sync in the freed slot, which
        // stops and exits at once.
        transport.send(Array("sync end".utf8), pid: 4, options: syncOptions(syncEnd))
        transport.send(lifecycle(exited, 4, syncProcess))
        transport.send(lifecycle(accepted, 4, syncProcess))
        transport.send(Array("sync stop".utf8), pid: 4, options: syncOptions(syncStop))
        transport.send(lifecycle(exited, 4, syncProcess))

        let stoppedPid = try await stop.value
        XCTAssertEqual(stoppedPid, 4)
        await waitUntil { delegate.exits.count == 2 && delegate.syncStates.count == 3 }
        XCTAssertEqual(delegate.syncStates, [.start, .end, .stop])
        XCTAssertEqual(delegate.exits.map(\.pid), [4, 4])
        XCTAssertEqual(delegate.exits.map(\.status), [nil, nil])
    }

    // -- Aidlab 2 4.1.0 -------------------------------------------------------

    func testAidlab2StopAnswersAfterTheSyncEndedThenClearRuns() async throws {
        let session = try await startSync(firmware: "4.1.0", pid: 21)
        let (transport, delegate, device) = (session.transport, session.delegate, session.device)
        let stop = Task { try await device.stopSynchronization() }
        await waitUntil { transport.commandText.contains("sync stop") }
        let clear = Task { try await device.clearSynchronization() }

        // SIGTERM: the sync reports SYNC_STOP and ends; the shell answers `accepted` and then sends the `exited` it
        // held back (128 + 15).
        transport.send(Array("sync stop".utf8), pid: 21, options: syncOptions(syncStop, 4096))
        transport.send(lifecycle(accepted, 21, syncProcess))
        transport.send(lifecycle(exited, 21, syncProcess, 143))
        let stoppedPid = try await stop.value
        XCTAssertEqual(stoppedPid, 21)

        // The clear reports the emptied storage before it exits.
        await waitUntil { transport.commandText.contains("sync clear") }
        transport.send(lifecycle(accepted, 22, syncProcess))
        transport.send(Array("sync count".utf8), pid: 22, options: syncOptions(syncCount))
        transport.send(lifecycle(exited, 22, syncProcess, 0))
        let cleared = try await clear.value
        XCTAssertEqual(cleared, 22)
        await waitUntil { delegate.exits.count == 2 }
        XCTAssertEqual(delegate.exits.map(\.pid), [21, 22])
        XCTAssertEqual(delegate.exits.map(\.status), [143, 0])
    }

    func testAidlab2ClearDuringTheSyncIsRejectedAsBusy() async throws {
        let session = try await startSync(firmware: "4.1.0", pid: 21)
        let (transport, device) = (session.transport, session.device)
        let clear = Task { try await device.clearSynchronization() }
        await waitUntil { transport.commandText.contains("sync clear") }

        transport.send(lifecycle(rejected, 0, syncProcess, 6))

        do {
            _ = try await clear.value
            XCTFail("a busy rejection must fail the clear")
        } catch let error as AidlabError {
            XCTAssertEqual(error.rejectionReason, .busy)
        }
    }

    func testAidlab2SyncThatEndsBeforeItsStopMakesTheStopReturnNil() async throws {
        let session = try await startSync(firmware: "4.1.0", pid: 21)
        let (transport, delegate, device) = (session.transport, session.delegate, session.device)
        let stop = Task { try await device.stopSynchronization() }
        await waitUntil { transport.commandText.contains("sync stop") }

        // No sync is left to stop: `accepted` with PID 0 and no `exited`.
        transport.send(Array("sync end".utf8), pid: 21, options: syncOptions(syncEnd))
        transport.send(lifecycle(exited, 21, syncProcess, 0))
        transport.send(lifecycle(accepted, 0, syncProcess))

        let stoppedPid = try await stop.value
        XCTAssertNil(stoppedPid)
        await waitUntil { delegate.syncStates.count == 2 }
        XCTAssertEqual(delegate.syncStates, [.start, .end])
    }

    func testStopAllowsExitTenSecondsAfterAcceptance() async throws {
        let session = try await startSync(firmware: "3.7.115", pid: 4)
        let stop = Task { try await session.device.stopSynchronization() }
        await waitUntil { session.transport.commandText.contains("sync stop") }
        session.transport.send(lifecycle(accepted, 4, syncProcess))

        try await Task.sleep(nanoseconds: 10_000_000_000)
        session.transport.send(lifecycle(exited, 4, syncProcess))

        let stoppedPid = try await stop.value
        XCTAssertEqual(stoppedPid, 4)
    }

    func testServicePidStopAllowsExitTenSecondsAfterSend() async throws {
        let session = try await startSync(firmware: "3.7.110", pid: 4)
        let stop = Task { try await session.device.stopSynchronization() }
        await waitUntil { session.transport.commandText.contains("sync stop") }
        // This firmware routes the stop directly to the sync PID, without a shell accepted response.
        try await Task.sleep(nanoseconds: 10_000_000_000)
        session.transport.send(lifecycle(exited, 4, syncProcess))

        let stoppedPid = try await stop.value
        XCTAssertEqual(stoppedPid, 4)
    }

    func testMissingExitTimesOutFromAcceptanceAndReleasesCommandGate() async throws {
        let session = try await startSync(firmware: "4.1.0", pid: 21)
        let stop = Task { try await session.device.stopSynchronization() }
        await waitUntil { session.transport.commandText.contains("sync stop") }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let acceptedAt = Date()
        session.transport.send(lifecycle(accepted, 21, syncProcess))

        do {
            _ = try await stop.value
            XCTFail("A missing exited must time out")
        } catch let error as AidlabError {
            XCTAssertEqual(error.message, "Timed out waiting for process exit")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(acceptedAt), 89.5)
        }

        let clear = Task { try await session.device.clearSynchronization() }
        await waitUntil { session.transport.commandText.contains("sync clear") }
        session.transport.send(lifecycle(accepted, 22, syncProcess))
        let clearedPid = try await clear.value
        XCTAssertEqual(clearedPid, 22)
    }

    // -- Helpers --------------------------------------------------------------

    /// Connects a device running `firmware` and starts a sync that the device runs as `pid`.
    private func startSync(firmware: String, pid: UInt16) async throws -> Session {
        let transport = TranscriptTransport(firmware: firmware)
        let delegate = TranscriptDelegate()
        let device = Device(transport: transport)
        try await device.connect(delegate: delegate)
        let started = Task { try await device.startSynchronization() }
        await waitUntil { transport.commandText.contains("sync fast") }
        transport.send(lifecycle(accepted, pid, syncProcess))
        transport.send(Array("sync start".utf8), pid: pid, options: syncOptions(syncStart))
        let startedPid = try await started.value
        XCTAssertEqual(startedPid, pid)
        await waitUntil { delegate.syncStates == [.start] }
        return Session(transport: transport, delegate: delegate, device: device)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}
