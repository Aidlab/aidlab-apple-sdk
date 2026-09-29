//
//  Copyright © 2026 Aidlab. All rights reserved.
//

@testable import Aidlab
import CoreBluetooth
import XCTest

private let commandCharacteristic = CBUUID(string: "51366E80-CF3A-11E1-9AB4-0002A5D5C51B")
private let ack: [UInt8] = [0x06]

private let createSuccess: UInt8 = 0
private let createFailure: UInt8 = 1
private let killSuccess: UInt8 = 2
private let syncProcess: UInt8 = 7
private let collectProcess: UInt8 = 8

/// A command frame that the device received from the SDK.
private struct HostFrame {
    let pid: UInt16
    let flags: UInt8
    let text: String
}

/// Transport that plays the device side of the command characteristic.
private final class MockTransport: AidlabTransport, @unchecked Sendable {
    let address = UUID()
    let name: String? = "Aidlab"
    var rssi: NSNumber = -50
    var mtuSize = 244
    var onDisconnect: ((DisconnectReason, Error?) -> Void)?

    let firmware: String
    var disconnectsSynchronously = false
    var onHostFrame: ((HostFrame) -> Void)?
    private(set) var hostFrames: [HostFrame] = []
    private(set) var subscriptions: Set<CBUUID> = []
    private(set) var writesOffMainQueue = 0
    private(set) var disconnectCalls = 0

    private var notifications: [CBUUID: (Data) -> Void] = [:]
    private var pending: [UInt8] = []
    private var expected = 0

    init(firmware: String) {
        self.firmware = firmware
    }

    private var usesV4: Bool { firmware.hasPrefix("4.") }

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { completion(.success(())) }
    }

    func disconnect() {
        disconnectCalls += 1
        if disconnectsSynchronously {
            onDisconnect?(.appDisconnected, nil)
        } else {
            DispatchQueue.main.async { self.onDisconnect?(.appDisconnected, nil) }
        }
    }

    func readCharacteristic(_ uuid: CBUUID, completion: @escaping (Result<Data, Error>) -> Void) {
        let values = ["2A29": "Aidlab", "2A25": "SN1", "2A26": firmware, "2A27": "2.0.0"]
        let value = values[uuid.uuidString.uppercased()] ?? ""
        DispatchQueue.main.async { completion(.success(Data(value.utf8))) }
    }

    func writeCharacteristic(_ uuid: CBUUID, data: Data, withResponse: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        if !Thread.isMainThread {
            writesOffMainQueue += 1
        }
        if uuid == commandCharacteristic {
            receive([UInt8](data))
        }
        if withResponse {
            DispatchQueue.main.async { completion(.success(())) }
        } else {
            completion(.success(()))
        }
    }

    func startNotifications(_ uuid: CBUUID, onData: @escaping (Data) -> Void, onError _: @escaping (Error) -> Void) {
        subscriptions.insert(uuid)
        notifications[uuid] = onData
    }

    func stopNotifications(_ uuid: CBUUID) {
        subscriptions.remove(uuid)
        notifications.removeValue(forKey: uuid)
    }

    /// Sends a notification on the command characteristic, as CoreBluetooth does, on the main queue.
    func notify(_ bytes: [UInt8]) {
        DispatchQueue.main.async {
            self.notifications[commandCharacteristic]?(Data(bytes))
        }
    }

    /// Replies from `pid`: V4 frames on Aidlab 2, V3.0 frames on Aidmed One 3.2-3.5.
    func reply(pid: UInt16, _ payload: [UInt8], requestAck: Bool = false) {
        if usesV4 {
            var header = [UInt8](repeating: 0, count: 20)
            header[0] = 4
            header[1] = 0x0A
            header[3] = UInt8(payload.count & 0xFF)
            header[4] = UInt8(payload.count >> 8)
            header[5] = UInt8(pid & 0xFF)
            header[6] = UInt8(pid >> 8)
            header[16] = requestAck ? 0x04 : 0
            notify(header + payload)
        } else {
            let size = payload.count + 7
            notify([3, 10, 99, UInt8(size & 0xFF), UInt8(size >> 8), UInt8(pid & 0xFF), UInt8(pid >> 8)] + payload)
        }
    }

    func lifecycle(pid: UInt8, processId: UInt8, status: UInt8 = createSuccess) {
        reply(pid: 0, [status, pid, 0, processId])
    }

    private func receive(_ bytes: [UInt8]) {
        if pending.isEmpty {
            if usesV4 {
                guard bytes.count >= 20, bytes[0] == 4 else { return }
                expected = 20 + Int(bytes[3]) + (Int(bytes[4]) << 8)
            } else {
                guard bytes.count >= 7, bytes[0] == 3 else { return }
                expected = Int(bytes[3]) + (Int(bytes[4]) << 8)
            }
        }
        pending += bytes
        guard pending.count >= expected else { return }
        let frame = pending
        pending = []
        let headerSize = usesV4 ? 20 : 7
        let payload = frame[headerSize...].filter { $0 != 0 }
        let hostFrame = HostFrame(
            pid: UInt16(frame[5]) | (UInt16(frame[6]) << 8),
            flags: usesV4 ? frame[16] : 0,
            text: String(bytes: payload, encoding: .utf8) ?? ""
        )
        hostFrames.append(hostFrame)
        onHostFrame?(hostFrame)
    }
}

private final class RecordingDelegate: DeviceDelegate, @unchecked Sendable {
    var connects = 0
    var disconnects: [DisconnectReason] = []
    var errors: [AidlabError] = []
    var terminated: [UInt16] = []
    var onConnect: ((Device) -> Void)?
    var onDisconnect: ((Device) -> Void)?
    var onPayload: ((Device) -> Void)?

    func didConnect(_ device: Device) {
        connects += 1
        onConnect?(device)
    }

    func didDisconnect(_ device: Device, reason: DisconnectReason) {
        disconnects.append(reason)
        onDisconnect?(device)
    }

    func didReceiveError(_: Device, error: AidlabError) {
        errors.append(error)
    }

    func didReceivePayload(_ device: Device, process _: String, payload _: Data, options _: UInt64) {
        onPayload?(device)
    }

    func processDidTerminate(_: Device, pid: UInt16) {
        terminated.append(pid)
    }

    func didReceiveECG(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveRespiration(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveBatteryLevel(_: Device, stateOfCharge _: UInt8) {}
    func didReceiveSteps(_: Device, timestamp _: UInt64, value _: UInt64) {}
    func didReceiveSkinTemperature(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceiveAccelerometer(_: Device, timestamp _: UInt64, ax _: Float, ay _: Float, az _: Float) {}
    func didReceiveGyroscope(_: Device, timestamp _: UInt64, gx _: Float, gy _: Float, gz _: Float) {}
    func didReceiveMagnetometer(_: Device, timestamp _: UInt64, mx _: Float, my _: Float, mz _: Float) {}
    func didReceiveQuaternion(_: Device, timestamp _: UInt64, qw _: Float, qx _: Float, qy _: Float, qz _: Float) {}
    func didReceiveOrientation(_: Device, timestamp _: UInt64, roll _: Float, pitch _: Float, yaw _: Float) {}
    func didReceiveEDA(_: Device, timestamp _: UInt64, conductance _: Float) {}
    func didReceiveGPS(_: Device, timestamp _: UInt64, latitude _: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) {}
    func didReceiveBodyPosition(_: Device, timestamp _: UInt64, bodyPosition _: BodyPosition) {}
    func didReceiveHeartRate(_: Device, timestamp _: UInt64, heartRate _: Int32) {}
    func didReceiveRr(_: Device, timestamp _: UInt64, rr _: Int32) {}
    func didReceiveRespirationRate(_: Device, timestamp _: UInt64, value _: UInt32) {}
    func didReceiveSoundVolume(_: Device, timestamp _: UInt64, soundVolume _: UInt16) {}
    func didDetectExercise(_: Device, exercise _: Exercise) {}
    func didReceiveActivity(_: Device, timestamp _: UInt64, activity _: ActivityType) {}
    func didUpdateRSSI(_: Device, rssi _: Int32) {}
    func wearStateDidChange(_: Device, wearState _: WearState) {}
    func didDetectUserEvent(_: Device, timestamp _: UInt64) {}
    func didReceiveSignalQuality(_: Device, timestamp _: UInt64, value _: UInt8) {}
    func syncStateDidChange(_: Device, state _: SyncState) {}
    func didReceivePastECG(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastRespiration(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastSkinTemperature(_: Device, timestamp _: UInt64, value _: Float) {}
    func didReceivePastHeartRate(_: Device, timestamp _: UInt64, heartRate _: Int32) {}
    func didReceivePastRr(_: Device, timestamp _: UInt64, rr _: Int32) {}
    func didReceiveUnsynchronizedSize(_: Device, unsynchronizedSize _: UInt32, syncBytesPerSecond _: Float) {}
    func didReceivePastRespirationRate(_: Device, timestamp _: UInt64, value _: UInt32) {}
    func didReceivePastActivity(_: Device, timestamp _: UInt64, activity _: ActivityType) {}
    func didReceivePastSteps(_: Device, timestamp _: UInt64, value _: UInt64) {}
    func didReceivePastSoundVolume(_: Device, timestamp _: UInt64, soundVolume _: UInt16) {}
    func didReceivePastAccelerometer(_: Device, timestamp _: UInt64, ax _: Float, ay _: Float, az _: Float) {}
    func didReceivePastGyroscope(_: Device, timestamp _: UInt64, gx _: Float, gy _: Float, gz _: Float) {}
    func didReceivePastMagnetometer(_: Device, timestamp _: UInt64, mx _: Float, my _: Float, mz _: Float) {}
    func didReceivePastQuaternion(_: Device, timestamp _: UInt64, qw _: Float, qx _: Float, qy _: Float, qz _: Float) {}
    func didReceivePastOrientation(_: Device, timestamp _: UInt64, roll _: Float, pitch _: Float, yaw _: Float) {}
    func didReceivePastEDA(_: Device, timestamp _: UInt64, conductance _: Float) {}
    func didReceivePastGPS(_: Device, timestamp _: UInt64, latitude _: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) {}
    func didReceivePastBodyPosition(_: Device, timestamp _: UInt64, bodyPosition _: BodyPosition) {}
    func didReceivePastPressure(_: Device, timestamp _: UInt64, value _: Int32) {}
    func didDetectPastUserEvent(_: Device, timestamp _: UInt64) {}
    func didReceivePastSignalQuality(_: Device, timestamp _: UInt64, value _: UInt8) {}
    func pressureWearStateDidChange(_: Device, wearState _: WearState) {}
    func didReceivePressure(_: Device, timestamp _: UInt64, value _: Int32) {}
}

private struct Session {
    let transport: MockTransport
    let delegate: RecordingDelegate
    let device: Device
}

/// Answers every V4 frame that requests it with an ACK, and shell commands with a lifecycle.
private func acknowledgeCommands(_ transport: MockTransport, pid: UInt8, processId: UInt8) {
    transport.onHostFrame = { [unowned transport] frame in
        if frame.flags & 0x04 != 0 {
            transport.notify(ack)
        }
        if frame.pid == 0 {
            transport.lifecycle(pid: pid, processId: processId)
        }
    }
}

@MainActor
final class DeviceTests: XCTestCase {
    /// Connects a device running `firmware` and waits for didConnect.
    private func connect(firmware: String = "4.0.3") async -> Session {
        let transport = MockTransport(firmware: firmware)
        let session = Session(transport: transport, delegate: RecordingDelegate(), device: Device(transport: transport))
        let connected = expectation(description: "didConnect")
        session.delegate.onConnect = { _ in connected.fulfill() }
        session.device.connect(delegate: session.delegate)
        await fulfillment(of: [connected], timeout: 2)
        session.delegate.onConnect = nil
        return session
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testCommandsFromBackgroundTasksReachTheCoreOnTheMainQueue() async throws {
        let session = await connect()
        acknowledgeCommands(session.transport, pid: 1, processId: collectProcess)
        let device = session.device

        let pid = try await Task.detached {
            try await device.collect(dataTypes: [.ecg], dataTypesToStore: [])
        }.value

        XCTAssertEqual(pid, 1)
        XCTAssertEqual(session.transport.writesOffMainQueue, 0)
    }

    func testDisconnectFromInsideACoreCallbackEndsTheSessionOnce() async {
        let session = await connect()
        session.transport.disconnectsSynchronously = true
        session.delegate.onPayload = { device in device.disconnect() }
        let disconnected = expectation(description: "didDisconnect")
        session.delegate.onDisconnect = { _ in disconnected.fulfill() }

        session.transport.reply(pid: 0, [0x09], requestAck: true)

        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(session.delegate.disconnects, [.appDisconnected])
        XCTAssertNil(session.device.aidlabSDK)
    }

    func testReconnectFromDidDisconnectStartsAWorkingSession() async {
        let session = await connect()
        let reconnected = expectation(description: "second didConnect")
        let delegate = session.delegate
        delegate.onDisconnect = { [unowned delegate] device in
            delegate.onConnect = { _ in reconnected.fulfill() }
            device.connect(delegate: delegate)
        }

        session.device.disconnect()

        await fulfillment(of: [reconnected], timeout: 2)
        XCTAssertEqual(delegate.connects, 2)
        XCTAssertNotNil(session.transport.onDisconnect)
    }

    func testNakFailsTheCommandAtOnce() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            if transport.hostFrames.count == 1 {
                transport.notify([0x15, 0x07])
            } else {
                transport.notify(ack)
                transport.lifecycle(pid: 2, processId: syncProcess)
            }
        }

        let start = Date()
        do {
            _ = try await session.device.startSynchronization()
            XCTFail("A NAK must fail the command")
        } catch let error as AidlabError {
            XCTAssertTrue(error.message.contains("NAK code 7"), error.message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)

        let pid = try await session.device.startSynchronization()
        XCTAssertEqual(pid, 2)
        XCTAssertEqual(session.delegate.disconnects, [])
    }

    func testProtocolErrorResetsTheSession() async {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            transport.notify([0x04, 0x0A, 0x00, 0x00, 0x00])
        }

        do {
            _ = try await session.device.startSynchronization()
            XCTFail("The reset must fail the pending command")
        } catch {}

        await waitUntil { session.delegate.disconnects == [.unknownError] }
        XCTAssertEqual(session.delegate.errors.first?.code, .protocol)
    }

    func testMissedAckReportsATimeout() async {
        let session = await connect()

        do {
            _ = try await session.device.startSynchronization()
            XCTFail("A missed ACK must fail the command")
        } catch let error as AidlabError {
            XCTAssertEqual(error.code, .transport)
        } catch {
            XCTFail("Unexpected \(error)")
        }

        await waitUntil { session.delegate.disconnects == [.timeout] }
    }

    func testRawSendWaitsForThePendingCommand() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            if frame.text.hasPrefix("sync") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    transport.lifecycle(pid: 2, processId: syncProcess)
                }
            } else {
                transport.lifecycle(pid: 5, processId: 3)
            }
        }
        let device = session.device
        let raw = Task { @MainActor in
            try await Task.sleep(nanoseconds: 50_000_000)
            try await device.send(Array("set led_brght 10\0".utf8))
        }

        let pid = try await device.startSynchronization()

        XCTAssertEqual(pid, 2)
        try await raw.value
        XCTAssertEqual(transport.hostFrames.map(\.text), ["sync fast", "set led_brght 10"])
    }

    func testRawShellCommandCompletesOnceDelivered() async throws {
        let session = await connect()
        let transport = session.transport
        // The kill builtin starts no process, so no create lifecycle follows.
        transport.onHostFrame = { [unowned transport] _ in transport.notify(ack) }

        try await session.device.send(Array("kill 5\0".utf8))

        XCTAssertEqual(transport.hostFrames.map(\.text), ["kill 5"])
    }

    func testSyncThatEndsBeforeItsStopArrivesIsStopped() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            if frame.text.hasPrefix("sync fast") {
                transport.notify(ack)
                transport.lifecycle(pid: 4, processId: syncProcess)
            } else {
                // The sync ended on its own, so the device refuses the frame addressed to it.
                transport.notify([0x15, 12])
                transport.lifecycle(pid: 4, processId: syncProcess, status: killSuccess)
            }
        }

        let started = try await session.device.startSynchronization()
        let stopped = try await session.device.stopSynchronization()

        XCTAssertEqual(started, 4)
        XCTAssertEqual(stopped, 4)
    }

    func testCommandIgnoresTheProcessOfAnEarlierRawCommand() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            if frame.text.hasPrefix("sync") {
                // The raw command's process starts after the next command went out.
                transport.lifecycle(pid: 5, processId: 3)
                transport.lifecycle(pid: 2, processId: syncProcess)
            }
        }

        try await session.device.send(Array("set led_brght 10\0".utf8))
        let pid = try await session.device.startSynchronization()

        XCTAssertEqual(pid, 2)
    }

    func testOutOfRangeProcessIdThrows() async {
        let session = await connect()

        do {
            try await session.device.send([1], processId: 70000)
            XCTFail("send accepted an out-of-range process ID")
        } catch {
            XCTAssertEqual((error as? AidlabError)?.message, "Invalid process ID 70000")
        }
    }

    func testStopCollectAfterReconnectAsksTheShell() async throws {
        let session = await connect()
        acknowledgeCommands(session.transport, pid: 3, processId: collectProcess)

        let pid = try await session.device.stopCollect()

        XCTAssertEqual(pid, 3)
        XCTAssertEqual(session.transport.hostFrames.map(\.text), ["collect off"])
        XCTAssertEqual(session.transport.hostFrames.first?.pid, 0)
    }

    func testFirmwareWithoutProcessesTakesCommandsWithoutLifecycle() async throws {
        let session = await connect(firmware: "2.2.12")
        let start = Date()

        let pid = try await session.device.startSynchronization()

        XCTAssertNil(pid)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testLegacyCollectSetsTheStorageFlagsAndSubscribes() async throws {
        let session = await connect(firmware: "3.5.61")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            transport.lifecycle(pid: 1, processId: syncProcess)
            transport.reply(pid: 1, Array("RECEIVED".utf8))
        }

        _ = try await session.device.collect(dataTypes: [.rr, .bodyPosition, .respirationRate, .pressure],
                                             dataTypesToStore: [.ecg, .rr])

        XCTAssertEqual(transport.hostFrames.map(\.text), [
            "sync enable ecg", "sync disable respir", "sync disable temper", "sync enable heartR",
            "sync disable orient", "sync disable accel", "sync disable activi", "sync disable steps",
        ])
        let expected = ["2A37", "63366E80-CF3A-11E1-9AB4-0002A5D5C51B", "48366E80-CF3A-11E1-9AB4-0002A5D5C51B",
                        "53366E80-CF3A-11E1-9AB4-0002A5D5C51B", "47366E80-CF3A-11E1-9AB4-0002A5D5C51B"]
        for uuid in expected {
            XCTAssertTrue(transport.subscriptions.contains(CBUUID(string: uuid)), uuid)
        }
    }

    func testConcurrentLegacyCollectsKeepTheirConfirmations() async throws {
        let session = await connect(firmware: "3.5.61")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            transport.lifecycle(pid: 1, processId: syncProcess)
            transport.reply(pid: 1, Array("RECEIVED".utf8))
        }
        let device = session.device

        async let first = device.collect(dataTypes: [.ecg], dataTypesToStore: [.ecg])
        async let second = device.collect(dataTypes: [.rr], dataTypesToStore: [])
        _ = try await (first, second)

        XCTAssertEqual(transport.hostFrames.count, 16)
    }

    func testCollectThatFindsASyncRunningSucceeds() async throws {
        let session = await connect(firmware: "3.7.107")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            transport.lifecycle(pid: 1, processId: collectProcess)
            // Firmware 3.7.84-3.7.110 starts a sync with collect and refuses it while another sync runs.
            transport.lifecycle(pid: 0, processId: syncProcess, status: createFailure)
        }

        let pid = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])

        XCTAssertEqual(pid, 1)
    }

    func testEndedCollectLeavesTheProcessTable() async throws {
        let session = await connect(firmware: "3.7.107")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            let pid = UInt8(2 * transport.hostFrames.count - 1)
            transport.lifecycle(pid: pid, processId: collectProcess)
            transport.lifecycle(pid: pid + 1, processId: syncProcess)
        }
        _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])
        // Firmware before 3.7.113 reports the ended collect process with a wrong process ID.
        transport.lifecycle(pid: 1, processId: 1, status: killSuccess)
        await waitUntil { session.delegate.terminated == [1] }

        let pid = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])

        XCTAssertEqual(pid, 3)
        XCTAssertEqual(transport.hostFrames.last?.pid, 0)
    }

    func testLegacyFirmwareCannotStoreSoundVolume() async {
        let session = await connect(firmware: "3.5.61")

        do {
            _ = try await session.device.collect(dataTypes: [], dataTypesToStore: [.soundVolume])
            XCTFail("Legacy firmware has no sound volume storage")
        } catch {}

        XCTAssertTrue(session.transport.hostFrames.isEmpty)
    }

    func testAidlab2WithMinorVersionEightConnects() async {
        let session = await connect(firmware: "4.8.0")

        XCTAssertEqual(session.delegate.connects, 1)
        XCTAssertEqual(session.delegate.disconnects, [])
    }

    func testRevisionThatTheCoreRejectsDoesNotConnect() async {
        let transport = MockTransport(firmware: "4.0")
        let delegate = RecordingDelegate()
        let device = Device(transport: transport)
        let disconnected = expectation(description: "didDisconnect")
        delegate.onDisconnect = { _ in disconnected.fulfill() }

        device.connect(delegate: delegate)

        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(delegate.connects, 0)
        XCTAssertEqual(delegate.disconnects, [.unknownError])
    }
}
