//
//  ObjectAttribute.swift
//  TablePro
//

import Foundation

/// One labelled property of a database object, in the order the driver listed it. The app renders
/// these and never interprets them, so per-engine vocabulary stays in the driver that speaks it.
struct ObjectAttribute: Identifiable, Hashable, Codable, Sendable {
    var id: String { label }
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
