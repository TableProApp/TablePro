//
//  EditorMenuAndStatementCountTests.swift
//  TableProTests
//

import Foundation
import Testing

struct EditorMenuAndStatementCountTests {
    /// Measured on this toolchain: `String(localized:)` hands back the key verbatim,
    /// `(^[1 statement](inflect: true))`, so a counted noun that has to end up in a `String` still
    /// needs two keys. Agreement is applied on the attributed path, which is the one `Text` uses,
    /// so a SwiftUI label gets it and a formatted string does not.
    @Test("A statement count agrees with its number in a label")
    func statementCountAgreesWithItsNumber() {
        let one = String(AttributedString(localized: "(^[\(1) statement](inflect: true))").characters)
        let many = String(AttributedString(localized: "(^[\(4) statement](inflect: true))").characters)

        #expect(one == "(1 statement)", "one measured as \(one)")
        #expect(many == "(4 statements)", "many measured as \(many)")
    }

    @Test("A counted noun bound for a plain String keeps its two keys")
    func plainStringCountKeepsTwoKeys() {
        let viaLocalized = String(localized: "(^[\(1) statement](inflect: true))")

        #expect(viaLocalized == "(^[1 statement](inflect: true))", "measured as \(viaLocalized)")
    }
}
