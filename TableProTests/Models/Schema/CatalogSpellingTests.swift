//
//  CatalogSpellingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct CatalogSpellingTests {
    private let type = CatalogSpelling(value: "geometry", spelling: "public.geometry(Point,4326)")

    @Test("The spelling applies while the field holds the value it was read with")
    func appliesToTheValueItWasReadWith() {
        #expect(type.spelling(for: "geometry") == "public.geometry(Point,4326)")
    }

    @Test("An edited field retires the spelling, and undoing the edit brings it back")
    func editRetiresAndUndoRestores() {
        #expect(type.spelling(for: "TEXT") == nil)
        #expect(type.spelling(for: "geometry") == "public.geometry(Point,4326)")
    }

    @Test("A field cleared to nil takes no spelling")
    func clearedFieldTakesNoSpelling() {
        let cleared: String? = nil
        #expect(type.spelling(for: cleared) == nil)
    }

    @Test("Two spellings are equal only when both the value and the spelling are")
    func equalityCoversValueAndSpelling() {
        #expect(type == CatalogSpelling(value: "geometry", spelling: "public.geometry(Point,4326)"))
        #expect(type != CatalogSpelling(value: "geography", spelling: "public.geometry(Point,4326)"))
        #expect(type != CatalogSpelling(value: "geometry", spelling: "extensions.geometry(Point,4326)"))
    }
}
