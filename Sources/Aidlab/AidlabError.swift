//
//  Created by Szymon Gęsicki on 11/02/2021.
//  Copyright © 2021-2023 Aidlab. All rights reserved.
//

import Foundation

class AidlabError: NSObject, LocalizedError {
    
    var message = ""
    
    init(message: String) { self.message = message }
    
    override var description: String {
        return "AidlabError: \(message)"
    }
    
    var errorDescription: String? {
        return self.description
    }
}
