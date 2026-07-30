//
//  Item.swift
//  speak_space_mobile
//
//  Created by tom on 30/07/2026.
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
