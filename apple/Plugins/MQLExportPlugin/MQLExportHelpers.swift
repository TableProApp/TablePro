//
//  MQLExportHelpers.swift
//  MQLExportPlugin
//

import Foundation
import TableProJavaScriptText
import TableProNumberFormatting
import TableProPluginKit

enum MQLExportHelpers {
    /// Spelled by the export's own rules rather than `MongoCollectionAccessor`'s, because this
    /// plugin can be released for an app that shipped an older copy of that helper.
    static func collectionAccessor(for name: String) -> String {
        guard JavaScriptText.isPlainIdentifier(name), !MongoCollectionAccessor.isShadowedByDatabaseMember(name) else {
            return "db.getCollection(\(JavaScriptText.stringLiteral(name)))"
        }
        return "db.\(name)"
    }

    static func headerComment(label: String, name: String) -> String {
        JavaScriptText.lineComment("\(label): \(name)")
    }

    static func documentLiteral(_ document: PluginExportDocument) throws -> String {
        var names = Set<Data>()
        let fields = try document.fields.map { field in
            guard names.insert(Data(field.name.utf8)).inserted else { throw PluginExportError.encodingFailed }
            let value = try canonicalValue(field.canonicalJSON)
            return "[\(JavaScriptText.stringLiteral(field.name)), \(value)]"
        }
        return "  new Map([\(fields.joined(separator: ", "))])"
    }

    static func canonicalValue(_ json: String) throws -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) != nil else {
            throw PluginExportError.encodingFailed
        }
        let escaped = json.unicodeScalars.map { scalar -> String in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return String(scalar) }
            return JavaScriptText.lineBreakingEscape(scalar) ?? String(scalar)
        }.joined()
        var reader = MQLScriptReader(tokens: MQLScriptLexer.lexemes(in: escaped).map(\.token))
        guard let value = reader.value(), reader.current == nil else { throw PluginExportError.encodingFailed }
        return try value.canonicalExpression()
    }

    static func insertCommand(collection: String, documents: [String]) -> String {
        let name = JavaScriptText.stringLiteral(collection)
        return checkedCommand("{insert: \(name), documents: [\n\(documents.joined(separator: ",\n"))\n], ordered: true}") + "\n"
    }

    static func checkedCommand(_ command: String) -> String {
        """
        {
          const result = db.runCommand(\(command));
          if (!result.ok || (result.writeErrors && result.writeErrors.length) || result.writeConcernError) {
            throw new Error("Document import failed: " + EJSON.stringify(result));
          }
        }
        """
    }
}

// A command has a BSON size limit too; reserving space keeps its array keys and metadata outside the document budget.
struct MQLDocumentBatch {
    static let documentByteLimit = 15 * 1_024 * 1_024

    private let countLimit: Int
    private var documents: [String] = []
    private var byteCount = 0

    init(countLimit: Int) {
        self.countLimit = min(100_000, max(1, countLimit))
    }

    mutating func append(_ literal: String, bsonSizeUpperBound: Int?) -> [[String]] {
        var ready: [[String]] = []
        guard let size = bsonSizeUpperBound, size > 0, size <= Self.documentByteLimit else {
            if !documents.isEmpty { ready.append(finish()) }
            ready.append([literal])
            return ready
        }
        var entrySize = size + String(documents.count).utf8.count + 2
        if byteCount > Self.documentByteLimit - entrySize {
            if !documents.isEmpty { ready.append(finish()) }
            entrySize = size + 3
        }
        documents.append(literal)
        byteCount += entrySize
        if documents.count >= countLimit { ready.append(finish()) }
        return ready
    }

    mutating func finish() -> [String] {
        let ready = documents
        documents.removeAll(keepingCapacity: true)
        byteCount = 0
        return ready
    }
}
