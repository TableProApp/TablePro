//
//  SQLFavoriteEditValidationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLFavoriteKeywordValidator")
struct SQLFavoriteKeywordValidatorTests {
    @Test("Empty keyword is valid regardless of availability")
    func emptyKeywordIsValid() {
        #expect(SQLFavoriteKeywordValidator.classify(trimmedKeyword: "", isAvailable: true) == .valid)
        #expect(SQLFavoriteKeywordValidator.classify(trimmedKeyword: "", isAvailable: false) == .valid)
    }

    @Test("Keyword containing a space is an error regardless of availability")
    func spaceIsError() {
        let available = SQLFavoriteKeywordValidator.classify(trimmedKeyword: "my keyword", isAvailable: true)
        let unavailable = SQLFavoriteKeywordValidator.classify(trimmedKeyword: "my keyword", isAvailable: false)
        #expect(available.blocksSave)
        #expect(unavailable.blocksSave)
        #expect(!available.isWarning)
        #expect(available.displayText != nil)
    }

    @Test("Unavailable keyword is an error")
    func unavailableIsError() {
        let result = SQLFavoriteKeywordValidator.classify(trimmedKeyword: "sel1", isAvailable: false)
        #expect(result.blocksSave)
        #expect(!result.isWarning)
        #expect(result.displayText != nil)
    }

    @Test("Reserved SQL keyword warns without blocking", arguments: ["select", "SELECT", "Select", "limit"])
    func reservedKeywordWarns(keyword: String) {
        let result = SQLFavoriteKeywordValidator.classify(trimmedKeyword: keyword, isAvailable: true)
        #expect(result.isWarning)
        #expect(!result.blocksSave)
        #expect(result.displayText?.contains(keyword.uppercased()) == true)
    }

    @Test("Available non-reserved keyword is valid")
    func availableKeywordIsValid() {
        #expect(SQLFavoriteKeywordValidator.classify(trimmedKeyword: "selusers", isAvailable: true) == .valid)
    }

    @Test("Availability check is required only for well-formed keywords")
    func requiresAvailabilityCheck() {
        #expect(!SQLFavoriteKeywordValidator.requiresAvailabilityCheck(""))
        #expect(!SQLFavoriteKeywordValidator.requiresAvailabilityCheck("my keyword"))
        #expect(SQLFavoriteKeywordValidator.requiresAvailabilityCheck("sel1"))
    }
}

@Suite("SQLFavoriteEditValidation")
struct SQLFavoriteEditValidationTests {
    @Test("Blank name blocks save")
    func blankNameBlocks() {
        #expect(!SQLFavoriteEditValidation.canSave(isNameBlank: true, isQueryBlank: false, keywordValidation: .valid))
    }

    @Test("Blank query blocks save")
    func blankQueryBlocks() {
        #expect(!SQLFavoriteEditValidation.canSave(isNameBlank: false, isQueryBlank: true, keywordValidation: .valid))
    }

    @Test("Keyword error blocks save")
    func keywordErrorBlocks() {
        #expect(!SQLFavoriteEditValidation.canSave(
            isNameBlank: false,
            isQueryBlank: false,
            keywordValidation: .error("taken")
        ))
    }

    @Test("Keyword warning does not block save")
    func keywordWarningAllows() {
        #expect(SQLFavoriteEditValidation.canSave(
            isNameBlank: false,
            isQueryBlank: false,
            keywordValidation: .warning("shadows")
        ))
    }

    @Test("Valid fields allow save")
    func validFieldsAllow() {
        #expect(SQLFavoriteEditValidation.canSave(isNameBlank: false, isQueryBlank: false, keywordValidation: .valid))
        #expect(SQLFavoriteEditValidation.canSave(isNameBlank: false, keywordValidation: .valid))
    }
}

@MainActor
@Suite("SQLFavoriteKeywordField")
struct SQLFavoriteKeywordFieldTests {
    @Test("Validation reflects the availability check result")
    func reflectsAvailability() async {
        let field = SQLFavoriteKeywordField { _, _, _ in false }
        field.keyword = "sel1"
        await field.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(field.validation.blocksSave)

        let availableField = SQLFavoriteKeywordField { _, _, _ in true }
        availableField.keyword = "sel1"
        await availableField.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(availableField.validation == .valid)
    }

    @Test("Malformed keywords skip the availability check")
    func malformedSkipsAvailabilityCheck() async {
        let field = SQLFavoriteKeywordField { _, _, _ in
            Issue.record("availability check should not run")
            return true
        }
        field.keyword = "my keyword"
        await field.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(field.validation.blocksSave)

        field.keyword = "   "
        await field.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(field.validation == .valid)
    }

    @Test("Keyword is trimmed before validation")
    func trimsKeyword() async {
        let field = SQLFavoriteKeywordField { keyword, _, _ in keyword == "sel1" }
        field.keyword = "  sel1  "
        await field.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(field.validation == .valid)
    }

    @Test("Stale availability responses are discarded")
    func staleResponseDiscarded() async {
        let (enteredStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseContinuation) = AsyncStream.makeStream(of: Bool.self)

        let field = SQLFavoriteKeywordField { keyword, _, _ in
            guard keyword == "slowkw" else { return true }
            enteredContinuation.yield()
            var iterator = releaseStream.makeAsyncIterator()
            return await iterator.next() ?? true
        }

        field.keyword = "slowkw"
        let slowValidation = Task {
            await field.validate(connectionId: nil, excludingFavoriteId: nil)
        }
        var enteredIterator = enteredStream.makeAsyncIterator()
        await enteredIterator.next()

        field.keyword = "fastkw"
        await field.validate(connectionId: nil, excludingFavoriteId: nil)
        #expect(field.validation == .valid)

        releaseContinuation.yield(false)
        await slowValidation.value
        #expect(field.validation == .valid)
    }
}
