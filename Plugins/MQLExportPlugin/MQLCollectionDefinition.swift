//
//  MQLCollectionDefinition.swift
//  MQLExportPlugin
//

import Foundation
import TableProJavaScriptText

/// The index and validator statements an MQL export writes after a collection's documents, read
/// from the definition the MongoDB driver reports for it.
///
/// That definition is shell text written around names the server chose, by whichever driver
/// version is installed, and copying it into the export copied whatever a name did to it. So it is
/// read instead, and only two shapes are written back: this collection's `createIndex` with
/// literal arguments, and a `collMod` that sets its validator. Each is written again from the
/// values read out of it. Anything else is left out, with a comment where it stood, and every
/// comment is written again on a line of its own.
///
/// A statement is read only where the driver starts one, at the start of a line, and the
/// validator only as the first, where the driver writes it. A statement that fails to read is left
/// out up to the next line, not one token at a time: stepping through it found a statement a name
/// had spelled inside it and wrote that out as one of the driver's own.
enum MQLCollectionDefinition {
    static let skippedStatementComment = "// Skipped a statement that is not an index or a validator"

    static func script(fromDDL ddl: String, collection: String) -> String {
        let lexemes = MQLScriptLexer.lexemes(in: ddl)
        guard let header = lexemes.firstIndex(where: isCollectionHeader) else { return "" }
        var reader = MQLScriptReader(tokens: lexemes.map(\.token), index: header + 1)
        var lines: [(text: String, followsBlankLine: Bool)] = []
        var isSkipping = false
        var hasPassedStatement = false

        while let token = reader.current {
            let lexeme = lexemes[reader.index]
            if token == .punctuator(";") {
                reader.advance()
            } else if case .lineComment(let text) = token {
                reader.advance()
                let comment = JavaScriptText.lineComment(text.trimmingCharacters(in: .whitespaces))
                lines.append((comment, lexeme.followsBlankLine))
                isSkipping = false
            } else if lexeme.followsLineBreak,
                      let statement = statement(&reader, collection: collection, readsValidator: !hasPassedStatement) {
                lines.append((statement, lexeme.followsBlankLine))
                isSkipping = false
                hasPassedStatement = true
            } else {
                skipToNextLine(&reader, lexemes: lexemes)
                if !isSkipping {
                    lines.append((skippedStatementComment, lexeme.followsBlankLine))
                }
                isSkipping = true
                hasPassedStatement = true
            }
        }

        return lines.enumerated()
            .map { offset, line in offset > 0 && line.followsBlankLine ? "\n" + line.text : line.text }
            .joined(separator: "\n")
    }

    private static func isCollectionHeader(_ lexeme: MQLScriptLexeme) -> Bool {
        guard case .lineComment(let text) = lexeme.token else { return false }
        return text.trimmingCharacters(in: .whitespaces).hasPrefix("Collection:")
    }

    private static func statement(
        _ reader: inout MQLScriptReader,
        collection: String,
        readsValidator: Bool
    ) -> String? {
        var attempt = reader
        var text = createIndexStatement(&attempt, collection: collection)
        if text == nil, readsValidator {
            attempt = reader
            text = validatorStatement(&attempt, collection: collection)
        }
        guard let text else { return nil }
        reader = attempt
        _ = reader.consume(";")
        return text
    }

    private static func skipToNextLine(_ reader: inout MQLScriptReader, lexemes: [MQLScriptLexeme]) {
        repeat {
            guard let token = reader.current else { return }
            reader.advance()
            if token == .punctuator(";") { return }
        } while reader.index < lexemes.count && !lexemes[reader.index].followsLineBreak
    }

    private static func createIndexStatement(_ reader: inout MQLScriptReader, collection: String) -> String? {
        guard let name = accessedCollection(&reader), isSameName(name, collection),
              reader.consume("."), reader.identifier() == "createIndex", reader.consume("("),
              case .object(let keys)? = reader.value() else {
            return nil
        }
        var arguments = [MQLScriptValue.object(keys)]
        if reader.consume(","), reader.current != .punctuator(")") {
            guard case .object(let options)? = reader.value() else { return nil }
            arguments.append(.object(options))
            _ = reader.consume(",")
        }
        guard reader.consume(")") else { return nil }
        let accessor = MQLExportHelpers.collectionAccessor(for: collection)
        return "\(accessor).createIndex(\(arguments.map(\.compactText).joined(separator: ", ")));"
    }

    private static func validatorStatement(_ reader: inout MQLScriptReader, collection: String) -> String? {
        guard reader.identifier() == "db", reader.consume("."), reader.identifier() == "runCommand",
              reader.consume("("), case .object(let command)? = reader.value(), reader.consume(")"),
              command.count == 2, command[0].key == "collMod", command[1].key == "validator",
              case .string(let name) = command[0].value, isSameName(name, collection),
              case .object = command[1].value else {
            return nil
        }
        let rebuilt = MQLScriptValue.object([MQLScriptMember(key: "collMod", value: .string(collection)), command[1]])
        return "db.runCommand(\(rebuilt.indentedText(depth: 0)));"
    }

    /// `db.<name>`, `db["<name>"]` or `db.getCollection("<name>")`, the three spellings a driver
    /// has written a collection in.
    private static func accessedCollection(_ reader: inout MQLScriptReader) -> String? {
        guard reader.identifier() == "db" else { return nil }
        if reader.consume("[") {
            guard let name = reader.string(), reader.consume("]") else { return nil }
            return name
        }
        guard reader.consume("."), let member = reader.identifier() else { return nil }
        guard member == "getCollection", reader.current == .punctuator("(") else { return member }
        guard reader.consume("("), let name = reader.string(), reader.consume(")") else { return nil }
        return name
    }

    /// Compared scalar by scalar: a server name is bytes, and `String` equality would take two
    /// canonically equivalent names for the same collection.
    private static func isSameName(_ name: String, _ collection: String) -> Bool {
        name.unicodeScalars.elementsEqual(collection.unicodeScalars)
    }
}
