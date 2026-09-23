//
//  SourceObjectDiffEngine.swift
//  TablePro
//
//  Compares the objects whose definition is a body of SQL: views, procedures,
//  functions and triggers.
//
//  Tables are deliberately not compared this way. Driver-rendered DDL varies by
//  formatting and by system-generated constraint names, and every tool that has
//  diffed table DDL as text has shipped a false-positive storm. A routine has no
//  parsed form to compare instead: its body IS the definition, so text is the
//  only thing there is. What that costs is a formatting-only difference reading
//  as a difference, which the normaliser below is there to reduce: it compares
//  the text each side would send, folds line endings, collapses runs of
//  whitespace, and folds case only when the compare options say identifier case
//  is ignored.
//

import Foundation
import TableProSQLGrammar

internal struct SourceObjectDiffEngine {
    private let options: StructureCompareOptions
    private let sourceScriptText: SQLScriptText
    private let targetScriptText: SQLScriptText

    internal init(
        options: StructureCompareOptions = .default,
        sourceDatabaseType: DatabaseType,
        targetDatabaseType: DatabaseType
    ) {
        self.options = options
        self.sourceScriptText = SQLScriptText(databaseType: sourceDatabaseType)
        self.targetScriptText = SQLScriptText(databaseType: targetDatabaseType)
    }

    internal func compare(
        source: [RoutineSourceRead],
        target: [RoutineSourceRead]
    ) -> [CompareObjectResult] {
        let targetByKey = Dictionary(
            target.map { (matchKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var handled: Set<String> = []
        var results: [CompareObjectResult] = []

        for read in source {
            let key = matchKey(for: read)
            handled.insert(key)
            results.append(result(identifiedBy: read, source: read, target: targetByKey[key]))
        }

        for read in target where !handled.contains(matchKey(for: read)) {
            results.append(result(identifiedBy: read, source: nil, target: read))
        }

        return results
    }

    private func result(
        identifiedBy read: RoutineSourceRead,
        source: RoutineSourceRead?,
        target: RoutineSourceRead?
    ) -> CompareObjectResult {
        let sourceDefect = source.flatMap { SourceDefinitionDefect.of($0, sentAs: targetScriptText) }
        let targetDefect = target.flatMap { SourceDefinitionDefect.of($0, sentAs: targetScriptText) }
        let comparisonError = sourceDefect.map { $0.reason(on: .source) } ?? targetDefect.map { $0.reason(on: .target) }
        return CompareObjectResult(
            identity: CompareObjectIdentity(
                kind: read.kind, schema: read.schema, name: read.name, signature: read.signature
            ),
            status: status(source: source, target: target, comparable: comparisonError == nil),
            sourceDefinition: source.map(displayedLines) ?? [],
            targetDefinition: target.map(displayedLines) ?? [],
            comparisonError: comparisonError
        )
    }

    private func status(
        source: RoutineSourceRead?,
        target: RoutineSourceRead?,
        comparable: Bool
    ) -> TableDiffStatus {
        guard let source else { return .onlyInTarget }
        guard let target else { return .onlyInSource }
        guard comparable else { return .differs }
        let equal = normalize(source.source, scriptText: sourceScriptText)
            == normalize(target.source, scriptText: targetScriptText)
        return equal ? .identical : .differs
    }

    private func displayedLines(_ read: RoutineSourceRead) -> [String] {
        guard read.failure == nil, StatementBlank.hasContent(read.source) else { return [] }
        return SqlNormalizer.lines(read.source)
    }

    private func matchKey(for read: RoutineSourceRead) -> String {
        let name = options.ignoreIdentifierCase ? read.name.lowercased() : read.name
        let schema = options.ignoreIdentifierCase ? (read.schema ?? "").lowercased() : (read.schema ?? "")
        let signature = (read.signature ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        return "\(read.kind.rawValue)|\(schema)|\(name)|\(signature)"
    }

    /// The text that would run is taken before any whitespace is folded. Folding first turns a line comment's
    /// newline into a space, so the comment swallows the rest of the body, and a unit's own `;` has to survive:
    /// Oracle stores `END` without it INVALID and with it VALID.
    private func normalize(_ source: String, scriptText: SQLScriptText) -> String {
        var text = scriptText.comparableText(SqlNormalizer.normalize(source))
        if options.ignoreWhitespaceInText {
            text = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            while text.contains("  ") {
                text = text.replacingOccurrences(of: "  ", with: " ")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.ignoreIdentifierCase ? text.lowercased() : text
    }
}
