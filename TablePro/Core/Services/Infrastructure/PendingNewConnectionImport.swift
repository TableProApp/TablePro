//
//  PendingNewConnectionImport.swift
//  TablePro
//

import Foundation

@MainActor
final class PendingNewConnectionImport {
    static let shared = PendingNewConnectionImport()

    private(set) var pending: ParsedConnectionURL?

    private init() {}

    func set(_ parsed: ParsedConnectionURL) {
        pending = parsed
    }

    func consume() -> ParsedConnectionURL? {
        defer { pending = nil }
        return pending
    }
}
