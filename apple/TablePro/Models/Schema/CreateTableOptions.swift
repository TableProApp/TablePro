//
//  CreateTableOptions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Nil engine, charset and collation write no clause, so the table takes what the server and its database give it.
struct CreateTableOptions: Hashable {
    var engine: String?
    var charset: String?
    var collation: String?
    var ifNotExists: Bool = false
    var comment: String = ""

    // A character set without a collation takes its default, and one from the previous set is an error (1253).
    func selectingCharacterSet(_ charset: String?, collation: String?) -> CreateTableOptions {
        var next = self
        next.charset = charset
        next.collation = collation
        return next
    }

    // Starts from what a table in the target database takes anyway, which the builder then leaves unwritten.
    func seeded(with defaults: CreateTableOptionDefaults) -> CreateTableOptions {
        var next = self
        if next.charset == nil {
            next.charset = defaults.characterSet
            next.collation = defaults.collation
        }
        if next.engine == nil {
            next.engine = defaults.engine
        }
        return next
    }
}

// What a new table in the target database takes when its statement names nothing: the database's default pair and
// the server's default engine.
struct CreateTableOptionDefaults: Hashable {
    var characterSet: String?
    var collation: String?
    var engine: String?

    // The pair is written whole or not at all: COLLATE alone moves the charset, and CHARACTER SET alone resets the
    // collation to the charset's default.
    func characterSetClause(for options: CreateTableOptions) -> (charset: String, collation: String?)? {
        guard let charset = options.charset?.nilIfEmpty else { return nil }
        let collation = options.collation?.nilIfEmpty
        if Self.matches(charset, characterSet), Self.matches(collation, self.collation) {
            return nil
        }
        return (charset, collation)
    }

    func engineClause(for options: CreateTableOptions) -> String? {
        guard let engine = options.engine?.nilIfEmpty, !Self.matches(engine, self.engine) else { return nil }
        return engine
    }

    private static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default:
            return false
        }
    }
}
