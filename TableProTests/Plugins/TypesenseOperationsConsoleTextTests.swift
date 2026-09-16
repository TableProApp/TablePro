//
//  TypesenseOperationsConsoleTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Typesense object operations as console text")
struct TypesenseOperationsConsoleTextTests {
    @Test("Dropping a collection is the native request")
    func dropIsNative() throws {
        let request = try #require(TypesenseOperations.dropCollection(named: "books", objectType: "TABLE"))
        #expect(TypesenseOperations.consoleText(request) == "DELETE /collections/books")
    }

    @Test("Truncating a collection keeps the truncate flag")
    func truncateKeepsFlag() {
        let text = TypesenseOperations.consoleText(TypesenseOperations.truncateCollection(named: "books"))
        #expect(text == "DELETE /collections/books/documents?truncate=true")
    }

    /// The statement is shown in the confirmation and then run, so a statement the driver's own
    /// parser rejects would be the #2884 defect in a second engine.
    @Test("Both statements parse as the requests they name")
    func statementsRoundTrip() throws {
        let drop = try #require(TypesenseOperations.dropCollection(named: "books", objectType: "TABLE"))
        let parsedDrop = try #require(TypesenseConsoleParser.parse(TypesenseOperations.consoleText(drop)))
        #expect(parsedDrop.method == "DELETE")
        #expect(parsedDrop.path == "/collections/books")

        let truncate = TypesenseOperations.truncateCollection(named: "books")
        let parsedTruncate = try #require(TypesenseConsoleParser.parse(TypesenseOperations.consoleText(truncate)))
        #expect(parsedTruncate.method == "DELETE")
        #expect(parsedTruncate.path == "/collections/books/documents?truncate=true")
    }

    /// A tagged blob has no leading verb, so `QueryClassifier` tiered a collection drop as an
    /// ordinary write and it skipped the destructive gate.
    @Test("A drop reads as destructive")
    func dropClassifiesDestructive() throws {
        let request = try #require(TypesenseOperations.dropCollection(named: "books", objectType: "TABLE"))
        let classification = QueryClassifier.classify(
            TypesenseOperations.consoleText(request), databaseType: .typesense
        )
        #expect(classification.tier == .destructive)
    }

    @Test("A truncate reads as destructive")
    func truncateClassifiesDestructive() {
        let text = TypesenseOperations.consoleText(TypesenseOperations.truncateCollection(named: "books"))
        #expect(QueryClassifier.classify(text, databaseType: .typesense).tier == .destructive)
    }
}
