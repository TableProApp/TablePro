//
//  StatementTextValidator.swift
//  TablePro
//

import Foundation

internal enum StatementTextValidator {
    static func validate(_ statement: String) throws {
        if let error = error(for: statement) {
            throw error
        }
    }

    static func error(for statement: String) -> DatabaseError? {
        containsNul(statement) ? .statementContainsNulCharacter : nil
    }

    private static func containsNul(_ statement: String) -> Bool {
        let contiguous = statement.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
            return memchr(base, 0, bytes.count) != nil
        }
        if let contiguous {
            return contiguous
        }
        return (statement as NSString).range(of: "\u{0}", options: .literal).location != NSNotFound
    }
}
