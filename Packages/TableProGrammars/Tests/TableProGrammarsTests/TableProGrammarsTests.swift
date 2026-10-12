import Foundation
import SwiftTreeSitter
@testable import TableProGrammars
import Testing

@Suite("TableProGrammars")
struct TableProGrammarsTests {
    @Test("Every grammar id but plain text resolves to a parser")
    func everyIDHasAParser() {
        for id in GrammarID.allCases where id != .plainText {
            let language = CodeLanguage.allLanguages.first { $0.id == id }
            #expect(language != nil, "\(id.rawValue) is declared but no CodeLanguage names it")
            #expect(language?.language != nil, "\(id.rawValue) resolves to no parser")
        }
    }

    @Test("Plain text has no parser, no query and no query file")
    func plainTextResolvesToNothing() {
        #expect(CodeLanguage.default.language == nil)
        #expect(CodeLanguage.default.queryURL == nil)
        #expect(HighlightQueries.shared.query(for: .plainText) == nil)
    }

    @Test("Every language's highlight query compiles against its own grammar")
    func everyHighlightQueryCompiles() {
        for language in CodeLanguage.allLanguages {
            #expect(HighlightQueries.shared.query(for: language.id) != nil, "\(language.id.rawValue) has no query")
        }
    }

    @Test("Every query file a language names is on disk")
    func everyNamedQueryFileExists() throws {
        for language in CodeLanguage.allLanguages {
            let primary = try #require(language.queryURL, "\(language.id.rawValue) names no highlights file")
            #expect(FileManager.default.fileExists(atPath: primary.path), "missing \(primary.lastPathComponent)")
            for name in language.additionalQueries {
                let url = try #require(language.queryURL(for: name))
                #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
            }
        }
    }

    @Test("The query directory does not shadow the bundle's own resources root")
    func queryDirectoryDoesNotShadowTheResourcesRoot() throws {
        let root = try #require(Bundle.module.resourceURL)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(names.contains("Queries"))
        #expect(
            !names.contains("Resources"),
            "a copied directory named Resources is taken as the resources root, which doubles every lookup path"
        )
    }

    @Test("The query cache hands back the same compiled query every time")
    func queriesAreCached() {
        let first = HighlightQueries.shared.query(for: .sql)
        let second = HighlightQueries.shared.query(for: .sql)
        #expect(first === second)
    }

    @Test("JSX reads the JavaScript grammar and its own highlights first")
    func jsxNarrowsJavaScript() {
        #expect(CodeLanguage.jsx.grammarName == CodeLanguage.javascript.grammarName)
        #expect(CodeLanguage.jsx.additionalQueries.contains("highlights-jsx"))
        #expect(CodeLanguage.jsx.queryURL == CodeLanguage.javascript.queryURL)
    }

    @Test("No two languages claim the same file extension")
    func extensionsDoNotCollide() {
        var seen: [String: GrammarID] = [:]
        for language in CodeLanguage.allLanguages {
            for fileExtension in language.extensions {
                #expect(seen[fileExtension] == nil, "\(fileExtension) is claimed by \(language.id.rawValue) and \(String(describing: seen[fileExtension]))")
                seen[fileExtension] = language.id
            }
        }
    }

    @Test("SQL comments are the ones the editor writes")
    func sqlCommentSyntax() {
        #expect(CodeLanguage.sql.lineCommentString == "--")
        #expect(CodeLanguage.sql.blockCommentStrings == ("/*", "*/"))
    }

    @Test("Every vendored grammar keeps its licence beside its sources")
    func everyGrammarShipsItsLicence() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TreeSitterGrammars")
        for name in ["bash", "javascript", "json", "sql"] {
            let licence = sources.appendingPathComponent(name).appendingPathComponent("LICENSE")
            let text = try String(contentsOf: licence, encoding: .utf8)
            #expect(text.contains("MIT"), "\(name) does not ship an MIT licence")
            #expect(text.contains("Copyright"), "\(name)'s licence carries no copyright line")
        }
    }
}
