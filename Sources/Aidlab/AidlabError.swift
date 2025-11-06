//
//  Created by Szymon Gęsicki on 11/02/2021.
//  Copyright © 2021-2023 Aidlab. All rights reserved.
//

import Foundation

final class AidlabError: NSObject, LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
        super.init()
    }

    override var description: String {
        "AidlabError: \(message)"
    }

    var errorDescription: String? {
        description
    }
}
