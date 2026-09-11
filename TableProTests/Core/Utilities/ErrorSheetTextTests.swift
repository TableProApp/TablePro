//
//  ErrorSheetTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Error sheet text")
struct ErrorSheetTextTests {
    @Test("A database message shows its hidden characters in the error sheet")
    func revealsHiddenCharacters() {
        let text = AlertHelper.errorInformativeText(
            message: "unrecognized token: \"\u{8}\"",
            recoverySuggestion: nil
        )
        #expect(text == "unrecognized token: \"<BS>\"")
    }

    @Test("The recovery suggestion follows the message after a blank line")
    func joinsRecoverySuggestion() {
        let text = AlertHelper.errorInformativeText(
            message: "column \"name\u{200B}\" does not exist",
            recoverySuggestion: "Check the column name."
        )
        #expect(text == "column \"name<ZWSP>\" does not exist\n\nCheck the column name.")
    }

    @Test("An empty part adds no blank lines")
    func dropsEmptyParts() {
        #expect(AlertHelper.errorInformativeText(message: "", recoverySuggestion: "Try again.") == "Try again.")
        #expect(AlertHelper.errorInformativeText(message: "Failed.", recoverySuggestion: "") == "Failed.")
    }

    @Test("A formatter's narrow no-break space is left alone")
    func keepsSpecialSpaces() {
        let message = "The session expired at 10:30\u{202F}PM."
        #expect(AlertHelper.errorInformativeText(message: message, recoverySuggestion: nil) == message)
    }
}
