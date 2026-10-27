//
//  Item.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
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
