//
//  MentionCandidate.swift
//  TablePro
//

import Foundation

struct MentionCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let item: ContextItem
    let displayLabel: String
    let secondaryLabel: String?
    let symbolName: String

    init(item: ContextItem, secondaryLabel: String? = nil) {
        self.item = item
        self.id = item.stableKey
        self.displayLabel = item.displayLabel
        self.secondaryLabel = secondaryLabel
        self.symbolName = item.symbolName
    }
}
