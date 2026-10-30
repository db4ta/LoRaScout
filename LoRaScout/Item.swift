//
//  Item.swift
//  LoRaScout
//
//  Created by Alex on 31.10.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
