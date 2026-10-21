//
//  Copyright © 2026 Aidlab. All rights reserved.
//

@testable import Aidlab
import struct AidlabSDK.AidlabEvent
import CoreBluetooth
import XCTest

private let commandCharacteristic = CBUUID(string: "51366E80-CF3A-11E1-9AB4-0002A5D5C51B")
private let ack: [UInt8] = [0x06]

private let accepted: UInt8 = 0
private let rejected: UInt8 = 1
private let exited: UInt8 = 2
private let syncProcess: UInt8 = 7
private let collectProcess: UInt8 = 8

/// A command frame that the device received from the SDK.
private struct HostFrame {
    /// The whole frame, header included.
    let bytes: [UInt8]
    let pid: UInt16
    let flags: UInt8
    let reserved: UInt8
    let options: UInt64
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
    func reply(pid: UInt16, _ payload: [UInt8], processType: UInt8 = 0, options: UInt64 = 0, requestAck: Bool = false) {
        if usesV4 {
            var header = [UInt8](repeating: 0, count: 20)
            header[0] = 4
            header[1] = 0x0A
            header[3] = UInt8(payload.count & 0xFF)
            header[4] = UInt8(payload.count >> 8)
            header[5] = UInt8(pid & 0xFF)
            header[6] = UInt8(pid >> 8)
            header[2] = processType
            for index in 0 ..< 8 {
                header[7 + index] = UInt8(truncatingIfNeeded: options >> (8 * index))
            }
            header[16] = requestAck ? 0x04 : 0
            notify(header + payload)
        } else {
            let size = payload.count + 7
            notify([3, 10, 99, UInt8(size & 0xFF), UInt8(size >> 8), UInt8(pid & 0xFF), UInt8(pid >> 8)] + payload)
        }
    }

    func lifecycle(pid: UInt8, processId: UInt8, status: UInt8 = accepted) {
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
            bytes: frame,
            pid: UInt16(frame[5]) | (UInt16(frame[6]) << 8),
            flags: usesV4 ? frame[16] : 0,
            reserved: usesV4 ? frame[2] : 0,
            options: usesV4 ? (0 ..< 8).reduce(UInt64(0)) { $0 | (UInt64(frame[7 + $1]) << (8 * $1)) } : 0,
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
    var exits: [(pid: UInt16, status: Int?)] = []
    var syncStates: [SyncState] = []
    var onSyncState: (() -> Void)?
    var onConnect: ((Device) -> Void)?
    var onDisconnect: ((Device) -> Void)?
    var onPayload: ((Device) -> Void)?
    var payloads: [(pid: UInt16, payload: Data, options: UInt64)] = []
    /// Data callbacks in arrival order, each with its first value.
    var dataCalls: [(method: String, value: String)] = []
    var events: [any DeviceEvent] = []

    private func record(_ value: Any, method: String = #function) {
        dataCalls.append((String(method.prefix { $0 != "(" }), "\(value)"))
    }

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

    func didReceiveProcessOutput(_ device: Device, pid: UInt16, payload: Data, options: UInt64) {
        payloads.append((pid, payload, options))
        onPayload?(device)
    }

    func processDidExit(_: Device, pid: UInt16, exitStatus: Int?) {
        exits.append((pid, exitStatus))
    }

    func didReceiveECG(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceiveRespiration(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceiveBatteryLevel(_: Device, stateOfCharge _: UInt8) {}
    func didReceiveSteps(_: Device, timestamp _: UInt64, value: UInt64) { record(value) }
    func didReceiveSkinTemperature(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceiveAccelerometer(_: Device, timestamp _: UInt64, ax: Float, ay _: Float, az _: Float) { record(ax) }
    func didReceiveGyroscope(_: Device, timestamp _: UInt64, gx: Float, gy _: Float, gz _: Float) { record(gx) }
    func didReceiveMagnetometer(_: Device, timestamp _: UInt64, mx: Float, my _: Float, mz _: Float) { record(mx) }
    func didReceiveQuaternion(_: Device, timestamp _: UInt64, qw: Float, qx _: Float, qy _: Float, qz _: Float) { record(qw) }
    func didReceiveOrientation(_: Device, timestamp _: UInt64, roll: Float, pitch _: Float, yaw _: Float) { record(roll) }
    func didReceiveEDA(_: Device, timestamp _: UInt64, conductance: Float) { record(conductance) }
    func didReceiveGPS(_: Device, timestamp _: UInt64, latitude: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) { record(latitude) }
    func didReceiveBodyPosition(_: Device, timestamp _: UInt64, bodyPosition: BodyPosition) { record(bodyPosition) }
    func didReceiveHeartRate(_: Device, timestamp _: UInt64, heartRate: Int32) { record(heartRate) }
    func didReceiveRr(_: Device, timestamp _: UInt64, rr: Int32) { record(rr) }
    func didReceiveRespirationRate(_: Device, timestamp _: UInt64, value: UInt32) { record(value) }
    func didReceiveSoundVolume(_: Device, timestamp _: UInt64, soundVolume: UInt16) { record(soundVolume) }
    func didUpdateRSSI(_: Device, rssi _: Int32) {}
    func didReceiveEvent(_: Device, event: any DeviceEvent) { events.append(event) }
    func didReceiveSignalQuality(_: Device, timestamp _: UInt64, value: UInt8) { record(value) }
    func syncStateDidChange(_: Device, state: SyncState) {
        syncStates.append(state)
        onSyncState?()
    }
    func didReceivePastECG(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceivePastRespiration(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceivePastSkinTemperature(_: Device, timestamp _: UInt64, value: Float) { record(value) }
    func didReceivePastHeartRate(_: Device, timestamp _: UInt64, heartRate: Int32) { record(heartRate) }
    func didReceivePastRr(_: Device, timestamp _: UInt64, rr: Int32) { record(rr) }
    func didReceiveUnsynchronizedSize(_: Device, unsynchronizedSize _: UInt32, syncBytesPerSecond _: Float) {}
    func didReceivePastRespirationRate(_: Device, timestamp _: UInt64, value: UInt32) { record(value) }
    func didReceivePastSteps(_: Device, timestamp _: UInt64, value: UInt64) { record(value) }
    func didReceivePastSoundVolume(_: Device, timestamp _: UInt64, soundVolume: UInt16) { record(soundVolume) }
    func didReceivePastAccelerometer(_: Device, timestamp _: UInt64, ax: Float, ay _: Float, az _: Float) { record(ax) }
    func didReceivePastGyroscope(_: Device, timestamp _: UInt64, gx: Float, gy _: Float, gz _: Float) { record(gx) }
    func didReceivePastMagnetometer(_: Device, timestamp _: UInt64, mx: Float, my _: Float, mz _: Float) { record(mx) }
    func didReceivePastQuaternion(_: Device, timestamp _: UInt64, qw: Float, qx _: Float, qy _: Float, qz _: Float) { record(qw) }
    func didReceivePastOrientation(_: Device, timestamp _: UInt64, roll: Float, pitch _: Float, yaw _: Float) { record(roll) }
    func didReceivePastEDA(_: Device, timestamp _: UInt64, conductance: Float) { record(conductance) }
    func didReceivePastGPS(_: Device, timestamp _: UInt64, latitude: Double, longitude _: Double, altitude _: Double, speed _: Float, heading _: Float, hdop _: Float) { record(latitude) }
    func didReceivePastBodyPosition(_: Device, timestamp _: UInt64, bodyPosition: BodyPosition) { record(bodyPosition) }
    func didReceivePastPressure(_: Device, timestamp _: UInt64, value: Int32) { record(value) }
    func didReceivePastSignalQuality(_: Device, timestamp _: UInt64, value: UInt8) { record(value) }
    func didReceivePressure(_: Device, timestamp _: UInt64, value: Int32) { record(value) }
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

/// Converts a core event of an `EventType` value that starts at 1700000000000.
private func decodedEvent(_ type: UInt32, code: Int32, end: UInt64 = 0, confidence: Float = -1, modelVersion: UInt32 = 0,
                          aux: String? = nil, subtyp: Int8 = 0, past: Bool = false) -> (any DeviceEvent)? {
    func decode(_ aux: UnsafePointer<CChar>?) -> (any DeviceEvent)? {
        makeDeviceEvent(AidlabEvent(type: type, code: code, timestamp: 1_700_000_000_000, endTimestamp: end,
                                    confidence: confidence, modelVersion: modelVersion, aux: aux, subtyp: subtyp),
                        past: past)
    }
    return aux.map { $0.withCString(decode) } ?? decode(nil)
}

@MainActor
final class DeviceTests: XCTestCase {
    func testReservedV4TypeHeaderIdentifiesSyncThroughLifecycle() async throws {
        let session = await connect()
        let transport = session.transport
        let syncStarted = expectation(description: "Sync data follows PID binding")
        session.delegate.onSyncState = { syncStarted.fulfill() }
        transport.onHostFrame = { [unowned transport] frame in
            XCTAssertEqual(frame.reserved, 0)
            XCTAssertEqual(frame.options, 0)
            transport.notify(ack)
            if frame.text.hasPrefix("sync") {
                // The raw ping has a different legacy lifecycle ID from Sync.
                transport.reply(pid: 0, [0, 41, 0, 2], options: 2)
                transport.reply(pid: 0, [0, 1, 2, syncProcess], options: 7)
                transport.reply(pid: 513, Array("sync start\0".utf8))
            }
        }
        try await session.device.send(Array("ping\0".utf8))
        let pid = try await session.device.startSynchronization()
        XCTAssertEqual(pid, 513)
        await fulfillment(of: [syncStarted], timeout: 1)
        XCTAssertEqual(session.delegate.syncStates, [.start])
        XCTAssertEqual(session.delegate.payloads.last?.options, 7)
        XCTAssertTrue(session.delegate.errors.isEmpty)
    }

    /// One serialized session that the core decodes into one sample of each of 18 data types, wear states of the
    /// electrodes and the cannula, an activity that goes on, and a user event.
    private func oneOfEachSession() throws -> [UInt8] {
        let hex = Array("0068e5cf8b010000e86be5cf8b01000000030000000103000000010200740e010048020020030200003c0400000003e8000012001000f80004000800f000008001e0fd8000500e00000000000000400000000000000001000204006400000002000f000800f469e5cf8b0100000100020100570c000000018bcfe568644020000020000000018bcfe568c84251000041a8000042c800003fc0000042b400003f400000")
        return try stride(from: 0, to: hex.count, by: 2).map {
            try XCTUnwrap(UInt8(String(hex[$0 ... $0 + 1]), radix: 16))
        }
    }

    func testCollectedDataIsLiveAndSynchronizedDataIsPast() async throws {
        let oneOfEach = try oneOfEachSession()
        let expected: [(live: String, past: String, value: String?)] = [
            ("didReceiveECG", "didReceivePastECG", nil),
            ("didReceiveRespiration", "didReceivePastRespiration", nil),
            ("didReceiveSkinTemperature", "didReceivePastSkinTemperature", "37.0"),
            ("didReceiveAccelerometer", "didReceivePastAccelerometer", "1.0"),
            ("didReceiveGyroscope", "didReceivePastGyroscope", nil),
            ("didReceiveMagnetometer", "didReceivePastMagnetometer", "30.0"),
            ("didReceiveQuaternion", "didReceivePastQuaternion", "1.0"),
            ("didReceiveOrientation", "didReceivePastOrientation", nil),
            ("didReceiveEDA", "didReceivePastEDA", "2.5"),
            ("didReceiveGPS", "didReceivePastGPS", "52.25"),
            ("didReceiveBodyPosition", "didReceivePastBodyPosition", "supine"),
            ("didReceiveHeartRate", "didReceivePastHeartRate", "72"),
            ("didReceiveRr", "didReceivePastRr", "800"),
            ("didReceiveRespirationRate", "didReceivePastRespirationRate", "15"),
            ("didReceiveSoundVolume", "didReceivePastSoundVolume", "60"),
            ("didReceiveSteps", "didReceivePastSteps", "100"),
            ("didReceiveSignalQuality", "didReceivePastSignalQuality", "87"),
            ("didReceivePressure", "didReceivePastPressure", "1000"),
        ]
        let session = await connect()
        let delegate = session.delegate
        acknowledgeCommands(session.transport, pid: 1, processId: collectProcess)
        _ = try await session.device.collect(dataTypes: [], dataTypesToStore: [], events: [.wearState, .activity, .user])
        session.transport.lifecycle(pid: 2, processId: syncProcess)

        session.transport.reply(pid: 1, oneOfEach)
        await waitUntil { delegate.dataCalls.count >= expected.count && delegate.events.count >= 3 }
        let live = delegate.dataCalls
        session.transport.reply(pid: 2, oneOfEach, options: 3 << 32) // NEXT_PACKAGE, nothing left
        await waitUntil { delegate.dataCalls.count >= live.count + expected.count && delegate.events.count >= 7 }
        let past = delegate.dataCalls.dropFirst(live.count)

        XCTAssertEqual(live.map(\.method).sorted(), expected.map(\.live).sorted())
        XCTAssertEqual(past.map(\.method).sorted(), expected.map(\.past).sorted())
        for (liveMethod, pastMethod, value) in expected where value != nil {
            XCTAssertEqual(live.first { $0.method == liveMethod }?.value, value, liveMethod)
            XCTAssertEqual(past.first { $0.method == pastMethod }?.value, value, pastMethod)
        }
        // Collect does not list the pressure wear state, so it arrives only through synchronization.
        let expectedEvents: [any DeviceEvent] = [false, true].flatMap { isPast -> [any DeviceEvent] in
            [WearStateEvent(timestamp: 1_700_000_000_000, endTimestamp: 1_700_000_000_000, confidence: nil,
                            isPast: isPast, wearState: .placedProperly),
             PressureWearStateEvent(timestamp: 1_700_000_000_000, endTimestamp: 1_700_000_000_000, confidence: nil,
                                    isPast: isPast, wearState: .detached),
             ActivityEvent(timestamp: 1_700_000_000_000, endTimestamp: nil, confidence: nil, isPast: isPast,
                           activity: .walking),
             UserEvent(timestamp: 1_700_000_000_500, endTimestamp: 1_700_000_000_500, confidence: nil, isPast: isPast)]
        }.filter { $0.isPast || !($0 is PressureWearStateEvent) }
        XCTAssertEqual(delegate.events.map { "\($0)" }, expectedEvents.map { "\($0)" })
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func testRejectedCollectKeepsTheEventsOfThePreviousOne() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] _ in
            transport.notify(ack)
            if transport.hostFrames.count == 1 {
                transport.lifecycle(pid: 1, processId: collectProcess)
            } else {
                transport.reply(pid: 0, [rejected, 0, 0, collectProcess, 5])
            }
        }
        _ = try await session.device.collect(dataTypes: [], dataTypesToStore: [], events: [.wearState])
        do {
            _ = try await session.device.collect(dataTypes: [], dataTypesToStore: [], events: [.activity])
            XCTFail("The device rejected the second collect")
        } catch {}

        transport.reply(pid: 1, try oneOfEachSession())

        await waitUntil { !session.delegate.events.isEmpty }
        XCTAssertEqual(session.delegate.events.map { "\(type(of: $0))" }, ["WearStateEvent"])
    }

    func testEmptyPayloadReachesAProcessButNotTheShell() async throws {
        let pid: UInt16 = 0x1234
        for firmware in ["3.7.113", "4.0.3"] {
            let session = await connect(firmware: firmware)
            let transport = session.transport
            transport.onHostFrame = { [unowned transport] frame in
                if frame.flags & 0x04 != 0 {
                    transport.notify(ack)
                }
            }

            try await session.device.send([], processId: Int(pid))
            do {
                try await session.device.send([])
                XCTFail("The shell takes only commands")
            } catch {}

            // A header with payload size 0 and the PID.
            let frames = transport.hostFrames.map(\.bytes)
            if firmware.hasPrefix("4.") {
                XCTAssertEqual(frames.map(\.count), [20])
                XCTAssertEqual(frames.first.map { Array($0[3 ... 6]) }, [0, 0, 0x34, 0x12])
            } else {
                XCTAssertEqual(frames, [[3, 0x0A, 1, 7, 0, 0x34, 0x12]])
            }
        }
    }

    /// Connects a device running `firmware`; connect returns after didConnect.
    private func connect(firmware: String = "4.0.3") async -> Session {
        let transport = MockTransport(firmware: firmware)
        let session = Session(transport: transport, delegate: RecordingDelegate(), device: Device(transport: transport))
        do {
            try await session.device.connect(delegate: session.delegate)
        } catch {
            XCTFail("connect failed: \(error)")
        }
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

    func testStdoutDeliversPidBytesAndOptionsBeforeExit() async throws {
        let session = await connect()
        let pid: UInt16 = 50000
        session.transport.reply(pid: 0, [accepted, UInt8(truncatingIfNeeded: pid), UInt8(pid >> 8), 5])
        let received = expectation(description: "streamed stdout")
        session.delegate.onPayload = { _ in
            if session.delegate.payloads.last?.pid == pid { received.fulfill() }
        }
        let bytes: [UInt8] = [0, 255, 10]
        let options = UInt64.max
        session.transport.reply(pid: pid, bytes, processType: 5, options: options)

        await fulfillment(of: [received], timeout: 2)
        let payload = try XCTUnwrap(session.delegate.payloads.last)
        XCTAssertEqual(payload.pid, pid)
        XCTAssertEqual(payload.payload, Data(bytes))
        XCTAssertEqual(payload.options, options)
        XCTAssertTrue(session.delegate.exits.isEmpty)
        session.delegate.onPayload = nil
    }

    func testExitReportsTheExitStatusWhenTheFirmwareSendsIt() async {
        let session = await connect()

        session.transport.reply(pid: 0, [exited, 5, 0, collectProcess, 143])
        session.transport.lifecycle(pid: 6, processId: syncProcess, status: exited)

        await waitUntil { session.delegate.exits.count == 2 }
        XCTAssertEqual(session.delegate.exits.map(\.pid), [5, 6])
        XCTAssertEqual(session.delegate.exits.map(\.status), [143, nil])
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
            Task { try await device.connect(delegate: delegate) }
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

    func testSyncStopsThroughTheShell() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            // The shell answers `sync stop` like a built-in, with the sync PID; the stop ends with its `exited`.
            transport.lifecycle(pid: 4, processId: syncProcess)
            if frame.text == "sync stop" {
                transport.lifecycle(pid: 4, processId: syncProcess, status: exited)
            }
        }

        let started = try await session.device.startSynchronization()
        let stopped = try await session.device.stopSynchronization()

        XCTAssertEqual(started, 4)
        XCTAssertEqual(stopped, 4)
        XCTAssertEqual(transport.hostFrames.map(\.pid), [0, 0])
    }

    func testSyncStopOnAidlab1From3_7_115LetsAClearFollowOnlyAfterTheSyncExits() async throws {
        let session = await connect(firmware: "3.7.115")
        let transport = session.transport
        var exitSent = false
        var clearSentAfterExit: Bool?
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            switch frame.text {
            case "sync stop":
                // 3.7.115 accepts the stop before the sync exits and rejects a clear until it does.
                transport.lifecycle(pid: 4, processId: syncProcess)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak transport] in
                    exitSent = true
                    transport?.lifecycle(pid: 4, processId: syncProcess, status: exited)
                }
            case "sync clear":
                clearSentAfterExit = exitSent
                transport.lifecycle(pid: 5, processId: syncProcess)
            default:
                transport.lifecycle(pid: 4, processId: syncProcess)
            }
        }

        _ = try await session.device.startSynchronization()
        let stopped = try await session.device.stopSynchronization()
        let cleared = try await session.device.clearSynchronization()

        XCTAssertEqual(stopped, 4)
        XCTAssertEqual(cleared, 5)
        XCTAssertEqual(clearSentAfterExit, true)
    }

    func testSyncStopWhoseExitArrivesWithItsAcceptanceEndsAtOnce() async throws {
        let session = await connect(firmware: "3.7.115")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            transport.lifecycle(pid: 4, processId: syncProcess)
            if frame.text == "sync stop" {
                transport.lifecycle(pid: 4, processId: syncProcess, status: exited)
            }
        }

        _ = try await session.device.startSynchronization()
        let stopped = try await session.device.stopSynchronization()

        XCTAssertEqual(stopped, 4)
    }

    func testDisconnectFailsASyncStopWaitingForTheSyncExit() async throws {
        let session = await connect(firmware: "3.7.115")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            transport.lifecycle(pid: 4, processId: syncProcess)
            if frame.text == "sync stop" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak transport] in transport?.disconnect() }
            }
        }
        _ = try await session.device.startSynchronization()

        do {
            _ = try await session.device.stopSynchronization()
            XCTFail("a disconnect must fail the stop")
        } catch let error as AidlabError {
            XCTAssertEqual(error.message, "Device disconnected")
        }
    }

    func testSyncStopFailsWhenTheSyncIsKilledInsteadOfExiting() async throws {
        let session = await connect(firmware: "3.7.115")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            transport.lifecycle(pid: 4, processId: syncProcess)
            if frame.text == "sync stop" {
                transport.lifecycle(pid: 4, processId: syncProcess, status: 3)
            }
        }
        _ = try await session.device.startSynchronization()

        do {
            _ = try await session.device.stopSynchronization()
            XCTFail("kill_failure must reject the stop")
        } catch let error as AidlabError {
            XCTAssertEqual(error.rejectionReason, .noSuchProcess)
        }
    }

    func testSyncStopFailsWhenTheShellRejectsTheSyncInsteadOfExiting() async throws {
        let session = await connect(firmware: "3.7.115")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            transport.lifecycle(pid: 4, processId: syncProcess)
            if frame.text == "sync stop" {
                transport.reply(pid: 0, [rejected, 4, 0, syncProcess, 6])
            }
        }
        _ = try await session.device.startSynchronization()

        do {
            _ = try await session.device.stopSynchronization()
            XCTFail("a rejection must fail the stop")
        } catch let error as AidlabError {
            XCTAssertEqual(error.rejectionReason, .busy)
        }
    }

    func testStopOfASyncThatEndedReturnsNil() async throws {
        let session = await connect()
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            transport.notify(ack)
            // The sync ended before its stop arrived, so the shell accepts the stop with PID 0.
            transport.lifecycle(pid: frame.text == "sync stop" ? 0 : 4, processId: syncProcess)
        }

        _ = try await session.device.startSynchronization()
        let stopped = try await session.device.stopSynchronization()

        XCTAssertNil(stopped)
        XCTAssertEqual(transport.hostFrames.map(\.text), ["sync fast", "sync stop"])
    }

    func testAidlab1KillFailureRejectsTheStopWithNoSuchProcess() async throws {
        let session = await connect(firmware: "3.7.113")
        let transport = session.transport
        transport.onHostFrame = { [unowned transport] frame in
            // Aidlab 1 answers a stop of a sync that already ended with kill_failure (status 3).
            transport.lifecycle(pid: 4, processId: syncProcess, status: frame.pid == 0 ? accepted : 3)
        }
        _ = try await session.device.startSynchronization()

        do {
            _ = try await session.device.stopSynchronization()
            XCTFail("kill_failure must reject the stop")
        } catch let error as AidlabError {
            XCTAssertEqual(error.rejectionReason, .noSuchProcess)
            XCTAssertEqual(error.message, "sync: no such process")
        }
        XCTAssertEqual(transport.hostFrames.map(\.pid), [0, 4])
    }

    func testRejectionCarriesItsReason() async throws {
        let session = await connect()
        let transport = session.transport
        let cases: [(answer: [UInt8], reason: RejectionReason, message: String)] = [
            ([rejected, 0, 0, collectProcess, 5], .invalidArgument, "collect: invalid arguments"),
            // Released firmware sends no reason byte.
            ([rejected, 0, 0, collectProcess], .unknown, "collect: unknown reason"),
        ]
        for (answer, reason, message) in cases {
            transport.onHostFrame = { [unowned transport] _ in
                transport.notify(ack)
                transport.reply(pid: 0, answer)
            }

            do {
                _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])
                XCTFail("\(answer) must reject collect")
            } catch let error as AidlabError {
                XCTAssertEqual(error.rejectionReason, reason)
                XCTAssertEqual(error.message, message)
            }
        }
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

    func testCommandIgnoresTheRejectionOfAnEarlierUnknownCommand() async throws {
        // Released firmware rejects an unknown command with one byte, the 2.8.0 model with ENOENT and no process.
        for unknownCommandRejection: [UInt8] in [[rejected], [rejected, 0, 0, 0xFF, 1]] {
            let session = await connect()
            let transport = session.transport
            transport.onHostFrame = { [unowned transport] frame in
                transport.notify(ack)
                if frame.text.hasPrefix("sync") {
                    // The shell rejects the unknown command after the next command went out.
                    transport.reply(pid: 0, unknownCommandRejection)
                    transport.lifecycle(pid: 2, processId: syncProcess)
                }
            }

            try await session.device.send(Array("unknown_command\0".utf8))
            let pid = try await session.device.startSynchronization()

            XCTAssertEqual(pid, 2)
        }
    }

    func testOneAddressHasOneConnectedDevice() async {
        let session = await connect()
        let other = Device(transport: session.transport)

        do {
            try await other.connect(delegate: RecordingDelegate())
            XCTFail("a second Device connected to the same address")
        } catch {
            XCTAssertEqual((error as? AidlabError)?.message, "Another Device is connected to \(session.transport.address)")
        }
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

    func testOnlyAidlab1UpTo3_7_113SendsCollectToTheCollectPid() async throws {
        let cases: [(firmware: String, pids: [UInt16])] = [
            ("3.7.113", [0, 1, 1]), ("3.7.114", [0, 0, 0]), ("4.0.3", [0, 0, 0]),
        ]
        for (firmware, pids) in cases {
            let session = await connect(firmware: firmware)
            acknowledgeCommands(session.transport, pid: 1, processId: collectProcess)

            _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])
            let collected = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])
            let stopped = try await session.device.stopCollect()

            XCTAssertEqual(collected, 1, firmware)
            XCTAssertEqual(stopped, 1, firmware)
            XCTAssertEqual(session.transport.hostFrames.map(\.pid), pids, firmware)
        }
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
                                             dataTypesToStore: [.ecg, .rr], events: [.activity])

        XCTAssertEqual(transport.hostFrames.map(\.text), [
            "sync enable ecg", "sync disable respir", "sync disable temper", "sync enable heartR",
            "sync disable orient", "sync disable accel", "sync enable activi", "sync disable steps",
        ])
        let expected = ["2A37", "63366E80-CF3A-11E1-9AB4-0002A5D5C51B", "48366E80-CF3A-11E1-9AB4-0002A5D5C51B",
                        "53366E80-CF3A-11E1-9AB4-0002A5D5C51B", "47366E80-CF3A-11E1-9AB4-0002A5D5C51B",
                        "61366E80-CF3A-11E1-9AB4-0002A5D5C51B"]
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
            transport.lifecycle(pid: 0, processId: syncProcess, status: rejected)
        }

        let pid = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])

        XCTAssertEqual(pid, 1)
    }

    func testHistoricalA1TableFullRejectionFailsTheCommandAndAllowsRetry() async throws {
        for (firmware, processId) in [("3.7.113", syncProcess), ("3.7.113", collectProcess),
                                      ("3.7.93", collectProcess)] {
            let session = await connect(firmware: firmware)
            let transport = session.transport
            let operation: () async throws -> UInt16? = {
                if processId == syncProcess {
                    return try await session.device.startSynchronization()
                }
                return try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])
            }
            transport.onHostFrame = { [unowned transport] _ in
                transport.lifecycle(pid: 0, processId: 0, status: rejected)
            }

            let start = Date()
            do {
                _ = try await operation()
                XCTFail("A full A1 process table must reject the command")
            } catch {
                XCTAssertEqual((error as? AidlabError)?.message,
                               "\(processId == syncProcess ? "sync" : "collect"): unknown reason")
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            XCTAssertEqual(session.delegate.payloads.last?.pid, 0)
            XCTAssertEqual(session.delegate.payloads.last?.payload, Data([rejected, 0, 0, 0]))

            transport.onHostFrame = { [unowned transport] _ in
                // Unrelated typed failures and an untyped success must not answer this command.
                transport.lifecycle(pid: 0, processId: processId == syncProcess ? collectProcess : syncProcess,
                                    status: rejected)
                transport.lifecycle(pid: 10, processId: 0)
                transport.lifecycle(pid: 3, processId: processId)
                if firmware == "3.7.93" {
                    transport.lifecycle(pid: 4, processId: syncProcess)
                }
            }
            let pid = try await operation()
            XCTAssertEqual(pid, 3)
            XCTAssertEqual(transport.hostFrames.count, 2)
            XCTAssertTrue(transport.hostFrames.allSatisfy { $0.pid == 0 })
        }
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
        transport.lifecycle(pid: 1, processId: 1, status: exited)
        await waitUntil { session.delegate.exits.map(\.pid) == [1] }

        let pid = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [])

        XCTAssertEqual(pid, 3)
        XCTAssertEqual(transport.hostFrames.last?.pid, 0)
    }

    func testCollectRejectsADataTypeTheFirmwareDoesNotSupport() async {
        let session = await connect(firmware: "3.7.113")

        do {
            _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [.eda])
            XCTFail("Firmware 3.7.113 has no EDA")
        } catch {
            XCTAssertEqual((error as? AidlabError)?.message, "Firmware 3.7.113 does not support eda")
        }

        XCTAssertTrue(session.transport.hostFrames.isEmpty)
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

        do {
            try await device.connect(delegate: delegate)
            XCTFail("connect accepted a revision that the core rejects")
        } catch {
            XCTAssertEqual((error as? AidlabError)?.message, "Unsupported firmware revision 4.0")
        }
        XCTAssertEqual(delegate.connects, 0)
        XCTAssertEqual(delegate.disconnects, [])
    }

    func testOnDeviceAnalysisEventsCarryTheirWfdbFieldsAndModelVersion() {
        let start: UInt64 = 1_700_000_000_000
        let cases: [((any DeviceEvent)?, any DeviceEvent)] = [
            (decodedEvent(5, code: 5, end: start, confidence: 0.875, modelVersion: 0x0201_0003, past: true),
             EcgEvent(timestamp: start, endTimestamp: start, confidence: 0.875, isPast: true, anntyp: 5, subtyp: 0, aux: nil, rhythm: nil, modelVersion: "2.1.3")),
            (decodedEvent(5, code: 28, confidence: 0.75, modelVersion: 0x0201_0003, aux: "(AFIB"),
             EcgEvent(timestamp: start, endTimestamp: nil, confidence: 0.75, isPast: false, anntyp: 28, subtyp: 0, aux: "(AFIB", rhythm: .atrialFibrillation, modelVersion: "2.1.3")),
            (decodedEvent(5, code: 28, end: start + 30000, confidence: 0.8, modelVersion: 0x0201_0003, aux: "(AFIB"),
             EcgEvent(timestamp: start, endTimestamp: start + 30000, confidence: 0.8, isPast: false, anntyp: 28, subtyp: 0, aux: "(AFIB", rhythm: .atrialFibrillation, modelVersion: "2.1.3")),
            (decodedEvent(5, code: 14, end: start + 30000, subtyp: 0x10),
             EcgEvent(timestamp: start, endTimestamp: start + 30000, confidence: nil, isPast: false, anntyp: 14, subtyp: 16, aux: nil, rhythm: .noise, modelVersion: nil)),
            (decodedEvent(6, code: 4, end: start + 1000, modelVersion: 0x0201_0003),
             SleepEvent(timestamp: start, endTimestamp: start + 1000, confidence: nil, isPast: false, period: .deep, modelVersion: "2.1.3")),
        ]
        for (decoded, expected) in cases {
            XCTAssertEqual(decoded.map { "\($0)" }, "\(expected)")
        }
        // Types this SDK version does not know: 7 of older development firmware and 8 of a later core.
        XCTAssertNil(decodedEvent(7, code: 6 << 8 | 1))
        XCTAssertNil(decodedEvent(8, code: 0))
    }

    func testEcgRhythmFollowsTheWfdbAnnotation() {
        let cases: [(anntyp: Int32, aux: String?, subtyp: Int8, rhythm: EcgRhythm?)] = [
            (28, "(AFIB", 0, .atrialFibrillation),
            (28, "(SBR", 0, .sinusBradycardia),
            (28, "(N", 0, .normalSinus),
            (14, nil, 0x10, .noise),
            (14, nil, 0x01, .noise),
            (14, nil, 0, .unknown),
            (28, "(VT", 0, .unknown),
            (28, nil, 0, .unknown),
            (1, nil, 0, nil),
            (5, nil, 0, nil),
            (13, nil, 0, nil),
            (16, nil, 0, nil),
        ]
        for (anntyp, aux, subtyp, rhythm) in cases {
            let event = decodedEvent(5, code: anntyp, aux: aux, subtyp: subtyp) as? EcgEvent
            XCTAssertNotNil(event)
            XCTAssertEqual(event?.rhythm, rhythm, "\(anntyp) \(aux ?? "nil") \(subtyp)")
        }
    }

    func testSleepPeriodFollowsTheCode() {
        let cases: [(code: Int32, period: SleepPeriod)] = [
            (0, .unknown), (1, .unknown), (2, .wake), (3, .light), (4, .deep), (5, .rem), (6, .unknown), (-1, .unknown),
        ]
        for (code, period) in cases {
            XCTAssertEqual((decodedEvent(6, code: code) as? SleepEvent)?.period, period, "\(code)")
        }
    }

    func testCollectEventsNeedAidlab2() async throws {
        let session = await connect(firmware: "3.7.113")

        do {
            _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [.eda],
                                                 events: [.ecg, .sleep])
            XCTFail("Aidlab 1 detects no events")
        } catch {
            XCTAssertEqual((error as? AidlabError)?.message,
                           "Firmware 3.7.113 does not support ecg, eda, sleep")
        }

        XCTAssertTrue(session.transport.hostFrames.isEmpty)

        let withoutEvents = await connect(firmware: "3.7.113")
        acknowledgeCommands(withoutEvents.transport, pid: 1, processId: collectProcess)
        _ = try await withoutEvents.device.collect(dataTypes: [.ecg], dataTypesToStore: [.heartRate])
        XCTAssertEqual(withoutEvents.transport.hostFrames.map(\.text), ["collect flags 00000001 00000100"])
    }

    func testAidlab2CollectSendsTheDataTypesAndDetectorsThatTheEventsNeed() async throws {
        let cases: [(events: [DeviceEventType], command: String)] = [
            ([.ecg, .sleep], "collect flags 00000001 00000100 00000060"),
            ([], "collect flags 00000001 00000100 00000000"),
            // Only the detectors of Aidlab 2 reach the events mask.
            ([.wearState, .user, .ecg], "collect flags 00000001 00000100 00000020"),
            // Activity adds its data type to the live and stored data.
            ([.activity], "collect flags 00000021 00000120 00000000"),
        ]
        for (events, command) in cases {
            let session = await connect(firmware: "4.0.3")
            acknowledgeCommands(session.transport, pid: 1, processId: collectProcess)
            _ = try await session.device.collect(dataTypes: [.ecg], dataTypesToStore: [.heartRate], events: events)
            XCTAssertEqual(session.transport.hostFrames.map(\.text), [command], "\(events)")
        }
    }
}
