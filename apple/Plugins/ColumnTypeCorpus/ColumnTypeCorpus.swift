//
//  ColumnTypeCorpus.swift
//  ColumnTypeCorpus
//

import Foundation

struct ColumnTypeCorpus: Decodable, Sendable {
    enum Step: String, CaseIterable, Sendable {
        case create, insert, columns, browse, stream, edit, csv, json, sql
    }

    struct Value: Decodable, Sendable {
        let sql: String
        // nil is SQL NULL. The key is required, so a forgotten expectation never reads as NULL.
        let cell: String?
        // For a value the server makes up, such as a rowversion: the cell has to match this instead.
        let matches: String?

        private enum CodingKeys: String, CodingKey { case sql, cell, `repeat`, matches }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sql = try container.decode(String.self, forKey: .sql)
            matches = try container.decodeIfPresent(String.self, forKey: .matches)
            if matches != nil {
                cell = nil
                return
            }
            guard container.contains(.cell) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.cell,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "\(sql) has no cell")
                )
            }
            let written = try container.decodeIfPresent(String.self, forKey: .cell)
            // A value too long to write out: `cell` repeated, as REPEAT('x', 70000) reads.
            let count = try container.decodeIfPresent(Int.self, forKey: .repeat) ?? 1
            cell = written.map { String(repeating: $0, count: count) }
        }
    }

    struct Edit: Decodable, Sendable {
        let row: Int?
        let text: String?
        let hex: String?
        let cell: String?
    }

    // A defect left for later, and what its failure looks like: any other failure at that step still fails the run.
    struct KnownIssue: Decodable, Sendable {
        let defect: String
        let matches: String
    }

    struct Column: Decodable, Sendable {
        let type: String
        let covers: [String]
        let values: [Value]
        let edit: Edit?
        let skip: [Step: String]
        let known: [Step: KnownIssue]

        private enum CodingKeys: String, CodingKey { case type, covers, values, edit, skip, known }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            covers = try container.decodeIfPresent([String].self, forKey: .covers) ?? [Self.baseName(of: type)]
            values = try container.decode([Value].self, forKey: .values)
            edit = try container.decodeIfPresent(Edit.self, forKey: .edit)
            skip = try Self.steps(container.decodeIfPresent([String: String].self, forKey: .skip), in: container, key: .skip)
            known = try Self.steps(
                container.decodeIfPresent([String: KnownIssue].self, forKey: .known), in: container, key: .known
            )
            if edit == nil, skip[.edit] == nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .edit, in: container, debugDescription: "\(type) needs an edit or a skip reason for it"
                )
            }
        }

        // The listed name a declaration stands for: `NUMERIC(10,2)` covers `NUMERIC`. Kept in step with
        // apple/scripts/ci/check-column-type-corpus.py.
        static func baseName(of type: String) -> String {
            let name = type.split(separator: "(", maxSplits: 1).first.map(String.init) ?? type
            return name.trimmingCharacters(in: .whitespaces)
        }

        private static func steps<Reason>(
            _ raw: [String: Reason]?,
            in container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> [Step: Reason] {
            var steps: [Step: Reason] = [:]
            for (name, reason) in raw ?? [:] {
                guard let step = Step(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "\(name) is not a step"
                    )
                }
                steps[step] = reason
            }
            return steps
        }
    }

    let engine: String
    let databaseTypeId: String
    let typeList: String
    let createTable: String
    let dropTable: String?
    let clearTable: String?
    // Listed types no column can have, such as SQL Server's CURSOR, with why.
    let notColumnTypes: [String: String]?
    // Polled after a save until it reads 0, for an engine that applies a save after answering it.
    let settleAfterSave: String?
    let columns: [Column]

    static func load(_ url: URL) throws -> ColumnTypeCorpus {
        try JSONDecoder().decode(ColumnTypeCorpus.self, from: Data(contentsOf: url))
    }

    func uncoveredTypes(listed: [String: [String]]) -> [String] {
        let covered = Set(columns.flatMap(\.covers)).union((notColumnTypes ?? [:]).keys)
        return listed.values.flatMap { $0 }.filter { !covered.contains($0) }.sorted()
    }

    // By what the column covers, else by the first word of its type: `TINYINT UNSIGNED` is an Integer.
    func category(of column: Column, listed: [String: [String]]) -> String? {
        let firstWord = Column.baseName(of: column.type).split(separator: " ").first.map(String.init) ?? column.type
        let names = column.covers + [firstWord]
        return listed.first { _, types in names.contains(where: types.contains) }?.key
    }
}
