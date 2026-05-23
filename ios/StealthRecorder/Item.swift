//
//  Item.swift
//  StealthRecorder
//
//  Created by Rork on May 23, 2026.
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
