//
//  ViewDefinitionFallbackTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// What Edit View Definition opens when the view's definition could not be read: the error as
/// comments in the tab's own language, then the engine's template, and nothing else that runs.
@MainActor
struct ViewDefinitionFallbackTests {
    private static let mongoTemplate = #"db.runCommand({ "collMod" : "v", "viewOn" : "source_collection" })"#

    /// The message a view named with every kind of line break carries: a carriage return alone, a
    /// carriage return and line feed, a line feed, U+2028, U+2029 and U+0085.
    private static let error = NSError(domain: "test", code: 1, userInfo: [
        NSLocalizedDescriptionKey:
            "No view named v\rdb.probe.drop(); x\r\ndb.a.drop();\ndb.b.drop();\u{2028}db.c.drop();\u{2029}db.d.drop();\u{85}db.e.drop(); in this database"
    ])

    private func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    @Test("A MongoDB tab gets the error as JavaScript comments, and the template is all that runs")
    func mongoFallbackRunsOnlyTheTemplate() {
        let text = MainContentCoordinator.viewDefinitionFallback(
            viewName: "v", error: Self.error, template: Self.mongoTemplate,
            lineComment: EditorLanguage.javascript.lineCommentMarker
        )

        let statements = JavaScriptStatementScanner.executableStatements(in: text).filter(\.hasContent)
        let code = statements.map {
            JavaScriptStatementScanner.strippingComments($0.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(code == [Self.mongoTemplate])
        let commented = lines(text).dropLast()
        #expect(commented.count == 8)
        #expect(commented.allSatisfy { $0.hasPrefix("// ") })
        #expect(lines(text).last == Self.mongoTemplate)
    }

    @Test("A SQL tab comments every line the error spans, whatever ends it")
    func sqlFallbackCommentsEveryLine() {
        let text = MainContentCoordinator.viewDefinitionFallback(
            viewName: "v", error: Self.error, template: nil,
            lineComment: EditorLanguage.sql.lineCommentMarker
        )
        let all = lines(text)

        #expect(all.first == "-- " + String(localized: "Could not fetch the view definition:"))
        #expect(all.dropLast(2).allSatisfy { $0.hasPrefix("-- ") })
        #expect(Array(all.suffix(2)) == ["CREATE OR REPLACE VIEW v AS", "SELECT * FROM table_name;"])
    }

    @Test("A language with no line comment gets the template alone")
    func languageWithoutCommentsGetsTheTemplate() {
        let text = MainContentCoordinator.viewDefinitionFallback(
            viewName: "v", error: Self.error, template: Self.mongoTemplate,
            lineComment: EditorLanguage.custom("surrealql").lineCommentMarker
        )

        #expect(text == Self.mongoTemplate)
    }

    @Test("Each editor language comments a line the way its grammar does")
    func lineCommentMarkers() {
        #expect(EditorLanguage.sql.lineCommentMarker == "--")
        #expect(EditorLanguage.javascript.lineCommentMarker == "//")
        #expect(EditorLanguage.bash.lineCommentMarker == "#")
        #expect(EditorLanguage.custom("kafkaql").lineCommentMarker.isEmpty)
    }
}
