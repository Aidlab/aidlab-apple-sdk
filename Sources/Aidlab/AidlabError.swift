//
//  Created by Szymon Gęsicki on 11/02/2021.
//  Copyright © 2021-2023 Aidlab. All rights reserved.
//

import Foundation

public final class AidlabError: NSObject, LocalizedError {
    public enum Code: Int32, Sendable {
        case none = 0
        case transport = 1000
        case `protocol` = 2000
        case sdk = 9000
    }

    public let code: Code
    public let message: String
    public let underlyingError: Error?

    public init(code: Code = .sdk, message: String, underlyingError: Error? = nil) {
        self.code = code
        self.message = message
        self.underlyingError = underlyingError
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

    public override var description: String {
        "AidlabError(code: \(code), message: \(message))"
    }

    public var errorDescription: String? {
        description
    }
}
