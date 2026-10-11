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
    private let targetIndexedKinds: Set<CompareObjectKind>

    internal init(
        options: StructureCompareOptions = .default,
        sourceDatabaseType: DatabaseType,
        targetDatabaseType: DatabaseType,
        targetIndexedKinds: Set<CompareObjectKind>
    ) {
        self.options = options
        self.sourceScriptText = SQLScriptText(databaseType: sourceDatabaseType)
        self.targetScriptText = SQLScriptText(databaseType: targetDatabaseType)
        self.targetIndexedKinds = targetIndexedKinds
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
        let sourceDefect = source.flatMap { SourceDefinitionDefect.of($0, sentAs: sourceScriptText) }
        let targetDefect = target.flatMap { SourceDefinitionDefect.of($0, sentAs: targetScriptText) }
        let indexes = indexComparison(source: source, target: target)
        let comparisonError = sourceDefect.map { $0.reason(on: .source) }
            ?? targetDefect.map { $0.reason(on: .target) }
            ?? indexes.failure
        let definitionMatches = comparisonError == nil && definitionsMatch(source: source, target: target)
        return CompareObjectResult(
            identity: CompareObjectIdentity(
                kind: read.kind, schema: read.schema, name: read.name, signature: read.signature
            ),
            status: status(
                source: source,
                target: target,
                comparable: comparisonError == nil,
                definitionMatches: definitionMatches,
                indexes: indexes
            ),
            changes: comparisonError == nil ? indexes.changes : [],
            sourceDefinition: source.map(displayedLines) ?? [],
            targetDefinition: target.map(displayedLines) ?? [],
            notes: comparisonError == nil ? indexes.notes : [],
            comparisonError: comparisonError,
            sourceIndexes: indexes.source,
            targetIndexes: indexes.target,
            definitionMatches: definitionMatches
        )
    }

    private func status(
        source: RoutineSourceRead?,
        target: RoutineSourceRead?,
        comparable: Bool,
        definitionMatches: Bool,
        indexes: IndexComparison
    ) -> TableDiffStatus {
        guard source != nil else { return .onlyInTarget }
        guard target != nil else { return .onlyInSource }
        guard comparable, definitionMatches else { return .differs }
        return indexes.changes.isEmpty && indexes.notes.isEmpty ? .identical : .differs
    }

    private func definitionsMatch(source: RoutineSourceRead?, target: RoutineSourceRead?) -> Bool {
        guard let source, let target else { return false }
        return normalize(source.source, scriptText: sourceScriptText)
            == normalize(target.source, scriptText: targetScriptText)
    }

    private struct IndexComparison {
        var source: [EditableIndexDefinition]?
        var target: [EditableIndexDefinition]?
        var changes: [SchemaChange] = []
        var notes: [String] = []
        var failure: String?
    }

    private func indexComparison(source: RoutineSourceRead?, target: RoutineSourceRead?) -> IndexComparison {
        var comparison = IndexComparison()
        if case .read(let found)? = target?.indexes {
            comparison.target = SourceObjectIndexes.definitions(found)
        }
        guard let source, let sourceRead = source.indexes else { return comparison }
        guard targetIndexedKinds.contains(source.kind) else {
            if target == nil, case .read(let found) = sourceRead, !SourceObjectIndexes.definitions(found).isEmpty {
                comparison.notes = [SourceObjectIndexes.notCarriedByTargetNote]
            }
            return comparison
        }
        switch sourceRead {
        case .failed(let reason):
            comparison.failure = String(format: String(localized: "The source's indexes could not be read: %@"), reason)
            return comparison
        case .read(let found):
            comparison.source = SourceObjectIndexes.definitions(found)
        }
        guard let target else { return comparison }
        guard let targetRead = target.indexes, let sourceIndexes = comparison.source else {
            comparison.source = nil
            return comparison
        }
        if case .failed(let reason) = targetRead {
            comparison.failure = String(format: String(localized: "The target's indexes could not be read: %@"), reason)
            return comparison
        }
        let outcome = StructureDiffEngine(options: options).indexChanges(
            source: sourceIndexes, target: comparison.target ?? []
        )
        comparison.changes = outcome.changes
        comparison.notes = outcome.notes
        return comparison
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
