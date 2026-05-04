//
//  PendingNewConnectionType.swift
//  TablePro
//

import Foundation

@MainActor
final class PendingNewConnectionType {
    static let shared = PendingNewConnectionType()

    private(set) var pending: DatabaseType?

    private init() {}

    func set(_ type: DatabaseType) {
        pending = type
    }

    func consume() -> DatabaseType? {
        defer { pending = nil }
        return pending
    }
}
