@preconcurrency import CoreBluetooth
import Foundation

public protocol AidlabTransport: AnyObject {
    var address: UUID { get }
    var name: String? { get }
    var rssi: NSNumber { get set }
    var mtuSize: Int { get }

    /// Called when the transport disconnects (including failures) after `connect`.
    /// - Note: The callback can be invoked on an arbitrary queue.
    var onDisconnect: ((DisconnectReason, Error?) -> Void)? { get set }

    func connect(completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()

    func readCharacteristic(_ uuid: CBUUID, completion: @escaping (Result<Data, Error>) -> Void)
    func writeCharacteristic(_ uuid: CBUUID, data: Data, withResponse: Bool, completion: @escaping (Result<Void, Error>) -> Void)

    func startNotifications(_ uuid: CBUUID, onData: @escaping (Data) -> Void, onError: @escaping (Error) -> Void)
    func stopNotifications(_ uuid: CBUUID)
}

protocol CoreBluetoothLifecycleForwarding: AnyObject {
    func notifyDidConnect()
    func notifyDidFailToConnect(error: Error?)
    func notifyDidDisconnect(error: Error?)
}
