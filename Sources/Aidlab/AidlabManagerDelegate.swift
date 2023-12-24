//
//  Created by Szymon Gęsicki on 31/05/2020.
//  Copyright © 2020-2023 Aidlab. All rights reserved.
//

import CoreBluetooth
import Foundation

public protocol AidlabManagerDelegate: AnyObject {
    func didDiscover(_ device: Device)
}
