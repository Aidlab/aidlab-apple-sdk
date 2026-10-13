//
//  Created by Szymon Gęsicki on 11/02/2021.
//  Copyright © 2021-2023 Aidlab. All rights reserved.
//

import Foundation

public final class AidlabError: NSObject, LocalizedError {
    /// Class of an error that ``DeviceDelegate/didReceiveError(_:error:)`` reports.
    public enum Code: Int32, Sendable {
        case none = 0
        /// The link failed, either a write or the frame confirmation deadline; the SDK ends the session.
        case transport = 1000
        /// The device broke the transport protocol; the SDK ends the session.
        case `protocol` = 2000
        /// A local condition, such as a misused API or device data that the SDK drops; the session continues.
        case sdk = 9000
    }

    public let code: Code
    public let message: String
    public let underlyingError: Error?
    /// Why the device rejected the command, or `nil` when the error is not a rejection.
    public let rejectionReason: RejectionReason?

    public init(
        code: Code = .sdk,
        message: String,
        underlyingError: Error? = nil,
        rejectionReason: RejectionReason? = nil
    ) {
        self.code = code
        self.message = message
        self.underlyingError = underlyingError
        self.rejectionReason = rejectionReason
        super.init()
    }

    static func wrapping(_ error: Error) -> AidlabError {
        if let aidlabError = error as? AidlabError {
            return aidlabError
        }
        return AidlabError(message: error.localizedDescription, underlyingError: error)
    }

    static func fromCore(rawCode: Int32, message: String) -> AidlabError {
        AidlabError(code: Code(rawValue: rawCode) ?? .sdk, message: message)
    }

    override public var description: String {
        "AidlabError(code: \(code), message: \(message))"
    }

    public var errorDescription: String? {
        description
    }
}

/// Why the device rejected a command.
public enum RejectionReason: Int, Sendable {
    /// `ENOENT`: the device does not know the command.
    case unknownCommand = 1
    /// `EAGAIN`: no free process slot.
    case noFreeSlot = 2
    /// `ENOMEM`: the device is out of memory.
    case outOfMemory = 3
    /// `E2BIG`: the command is too long.
    case commandTooLong = 4
    /// `EINVAL`: a running service rejected the arguments.
    case invalidArgument = 5
    /// `EBUSY`: the command conflicts with the device state, e.g. `sync clear` during a sync.
    case busy = 6
    /// `ESRCH`: `kill` found no such process.
    case noSuchProcess = 7
    /// `EPERM`: `kill` is not permitted.
    case notPermitted = 8
    /// `ENOTCONN`: no client or a stale session.
    case notConnected = 9
    /// `ESHUTDOWN`: the process manager is stopping.
    case shuttingDown = 10
    /// The firmware does not report the reason, or this SDK version does not know it.
    case unknown = -1

    /// The cause as a rejection message reads it, e.g. "invalid arguments".
    var text: String {
        switch self {
        case .unknownCommand: "unknown command"
        case .noFreeSlot: "no free process slot"
        case .outOfMemory: "out of memory"
        case .commandTooLong: "command too long"
        case .invalidArgument: "invalid arguments"
        case .busy: "busy"
        case .noSuchProcess: "no such process"
        case .notPermitted: "not permitted"
        case .notConnected: "not connected"
        case .shuttingDown: "shutting down"
        case .unknown: "unknown reason"
        }
    }
}
