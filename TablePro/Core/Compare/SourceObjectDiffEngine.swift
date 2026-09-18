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
//  as a difference, which the normaliser below is there to reduce: it folds
//  line endings, collapses runs of whitespace and drops trailing semicolons,
//  and it folds case only when the compare options say identifier case is
//  ignored.
//

import Foundation

internal struct SourceObjectDiffEngine {
    private let options: StructureCompareOptions

    internal init(options: StructureCompareOptions = .default) {
        self.options = options
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
            guard let counterpart = targetByKey[key] else {
                results.append(result(for: read, counterpart: nil, status: .onlyInSource))
                continue
            }
            let equal = normalize(read.source) == normalize(counterpart.source)
            results.append(result(for: read, counterpart: counterpart, status: equal ? .identical : .differs))
        }

        for read in target where !handled.contains(matchKey(for: read)) {
            results.append(result(for: read, counterpart: nil, status: .onlyInTarget))
        }

        return results
    }

    private func result(
        for read: RoutineSourceRead,
        counterpart: RoutineSourceRead?,
        status: TableDiffStatus
    ) -> CompareObjectResult {
        let identity = CompareObjectIdentity(
            kind: read.kind, schema: read.schema, name: read.name, signature: read.signature
        )
        let sourceLines = status == .onlyInTarget ? [] : SqlNormalizer.lines(read.source)
        let targetLines: [String]
        switch status {
        case .onlyInTarget:
            targetLines = SqlNormalizer.lines(read.source)
        case .onlyInSource:
            targetLines = []
        case .differs, .identical:
            targetLines = SqlNormalizer.lines(counterpart?.source ?? "")
        }
        return CompareObjectResult(
            identity: identity,
            status: status,
            sourceDefinition: sourceLines,
            targetDefinition: targetLines,
            notes: notes(for: read, status: status)
        )
    }

    private func notes(for read: RoutineSourceRead, status: TableDiffStatus) -> [String] {
        guard status != .identical, read.source.isEmpty else { return [] }
        return [String(localized: "The driver did not return this object's definition, so only its name was compared.")]
    }

    private func matchKey(for read: RoutineSourceRead) -> String {
        let name = options.ignoreIdentifierCase ? read.name.lowercased() : read.name
        let schema = options.ignoreIdentifierCase ? (read.schema ?? "").lowercased() : (read.schema ?? "")
        let signature = (read.signature ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        return "\(read.kind.rawValue)|\(schema)|\(name)|\(signature)"
    }

    private func normalize(_ source: String) -> String {
        var text = SqlNormalizer.normalize(source)
        if options.ignoreWhitespaceInText {
            text = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            while text.contains("  ") {
                text = text.replacingOccurrences(of: "  ", with: " ")
            }
        }
        while text.hasSuffix(";") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.ignoreIdentifierCase ? text.lowercased() : text
    }
}
