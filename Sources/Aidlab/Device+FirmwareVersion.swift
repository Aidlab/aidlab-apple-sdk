//
//  Created by Jakub Domaszewicz.
//  Copyright © 2026 Aidlab. All rights reserved.
//

import Foundation

extension Device {
    func usesV4Protocol() -> Bool {
        guard let firmwareRevision else { return false }
        let sanitized = firmwareRevision.split(separator: "-").first.map(String.init) ?? firmwareRevision
        guard let current = SemVersion(sanitized),
              let threshold = SemVersion("4.0.0")
        else { return false }
        return current >= threshold
    }

    func hasCollectAutoSyncBug() -> Bool {
        guard let firmwareRevision else { return false }
        let sanitized = firmwareRevision.split(separator: "-").first.map(String.init) ?? firmwareRevision
        guard let current = SemVersion(sanitized),
              let firstAffected = SemVersion("3.7.85"),
              let lastAffected = SemVersion("3.7.110")
        else { return false }
        return current >= firstAffected && current <= lastAffected
    }

    func synchronizationStartCommand() -> String {
        guard let firmwareRevision else { return "sync start" }
        let sanitized = firmwareRevision.split(separator: "-").first.map(String.init) ?? firmwareRevision
        guard let current = SemVersion(sanitized),
              let firstFastVersion = SemVersion("3.7.83")
        else { return "sync start" }
        return current >= firstFastVersion ? "sync fast" : "sync start"
    }

    func commandBytes(_ command: String) -> [UInt8] {
        var bytes = Array(command.utf8)
        if bytes.isEmpty || bytes.last != 0 {
            bytes.append(0)
        }
        return bytes
    }
}

struct SemVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ version: String) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        major = parts[0]
        minor = parts[1]
        patch = parts[2]
    }

    static func < (lhs: SemVersion, rhs: SemVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }

    static func == (lhs: SemVersion, rhs: SemVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}
