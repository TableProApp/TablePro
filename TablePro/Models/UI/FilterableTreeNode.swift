//
//  FilterableTreeNode.swift
//  TablePro
//

import Foundation

internal protocol FilterableTreeNode: Identifiable {
    var key: String? { get }
    var keyPath: String { get }
    var displayValue: String { get }
    var searchableText: String { get }
    var copyableValue: String { get }
    var badgeLabel: String { get }
    var isTruncationMarker: Bool { get }
    var children: [Self] { get }

    func replacingChildren(_ children: [Self]) -> Self
}

internal extension FilterableTreeNode {
    var isContainer: Bool {
        !children.isEmpty
    }

    var accessibilityDescription: String {
        let value = displayValue as NSString
        let head = value.length > 120 ? value.substring(to: 120) : displayValue
        guard let key, !key.isEmpty else { return "\(badgeLabel), \(head)" }
        return "\(key), \(badgeLabel), \(head)"
    }
}
