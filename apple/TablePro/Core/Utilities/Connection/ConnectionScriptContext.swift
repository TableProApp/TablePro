//
//  ConnectionScriptContext.swift
//  TablePro
//

import Foundation

struct ConnectionScriptContext: Equatable, Sendable {
    let connectionId: UUID
    let connectionName: String
    let host: String
    let port: Int
    let user: String
    let database: String

    var environment: [String: String] {
        [
            "TABLEPRO_CONNECTION_NAME": connectionName,
            "TABLEPRO_HOST": host,
            "TABLEPRO_PORT": String(port),
            "TABLEPRO_USER": user,
            "TABLEPRO_DATABASE": database
        ]
    }

    // A placeholder becomes its TABLEPRO_ variable, never the value as source, so a hostile name cannot run as code.
    func substitutingPlaceholders(in command: String) -> String {
        var rewriter = PlaceholderRewriter(command: command)
        return rewriter.rewrite()
    }
}

private struct PlaceholderRewriter {
    private struct HereDocument {
        let delimiter: String
        let stripsTabs: Bool
        let expands: Bool
    }

    private let command: String
    private var index: String.Index
    private var output = ""
    private var contexts: [ShellContext] = [.plain]
    private var pendingHereDocuments: [HereDocument] = []

    init(command: String) {
        self.command = command
        index = command.startIndex
    }

    mutating func rewrite() -> String {
        while index < command.endIndex {
            let character = command[index]
            let next = command.index(after: index)
            let context = contexts.last ?? .plain

            if character == "#", context.isUnquoted, startsWord(at: index) {
                let lineEnd = command[index...].firstIndex(of: "\n") ?? command.endIndex
                output += command[index ..< lineEnd]
                index = lineEnd
                continue
            }
            if character == "{", !follows("$", at: index), let (variable, end) = placeholder(at: index) {
                output += context.reference(to: variable)
                index = end
                continue
            }
            if character == "<", context.isUnquoted, context != .group, !follows("<", at: index),
               readHereDocumentOperator() {
                continue
            }

            output.append(character)
            index = next
            switch character {
            case "\\" where context != .single && next < command.endIndex:
                output.append(command[next])
                index = command.index(after: next)
            case "\n" where context.isUnquoted && !pendingHereDocuments.isEmpty:
                copyHereDocumentBodies()
            case "'" where context == .single:
                contexts.removeLast()
            case "'" where context != .double:
                contexts.append(.single)
            case "\"" where context == .double:
                contexts.removeLast()
            case "\"" where context != .single:
                contexts.append(.double)
            case "$" where context != .single && next < command.endIndex && command[next] == "(":
                output.append("(")
                contexts.append(.substitution)
                index = command.index(after: next)
            case "(" where context == .substitution || context == .group:
                contexts.append(.group)
            case ")" where context == .substitution || context == .group:
                contexts.removeLast()
            case "`" where context == .backtick:
                contexts.removeLast()
            case "`" where context != .single:
                contexts.append(.backtick)
            default:
                break
            }
        }
        return output
    }

    // `<<WORD` and `<<-WORD`; `<<<` is a here-string and stays ordinary syntax.
    private mutating func readHereDocumentOperator() -> Bool {
        let rest = command[index...]
        guard rest.hasPrefix("<<"), !rest.hasPrefix("<<<") else { return false }
        var cursor = command.index(index, offsetBy: 2)
        let stripsTabs = cursor < command.endIndex && command[cursor] == "-"
        if stripsTabs {
            cursor = command.index(after: cursor)
        }
        while cursor < command.endIndex, command[cursor] == " " || command[cursor] == "\t" {
            cursor = command.index(after: cursor)
        }
        let wordStart = cursor
        while cursor < command.endIndex, !command[cursor].isWhitespace, !";|&()<>".contains(command[cursor]) {
            cursor = command.index(after: cursor)
        }
        let word = command[wordStart ..< cursor]
        guard !word.isEmpty else { return false }
        let quoted = word.contains { "'\"\\".contains($0) }
        pendingHereDocuments.append(HereDocument(
            delimiter: String(word.filter { !"'\"\\".contains($0) }),
            stripsTabs: stripsTabs,
            expands: !quoted
        ))
        output += command[index ..< cursor]
        index = cursor
        return true
    }

    private mutating func copyHereDocumentBodies() {
        for document in pendingHereDocuments {
            while index < command.endIndex {
                let lineEnd = command[index...].firstIndex(of: "\n") ?? command.endIndex
                let line = command[index ..< lineEnd]
                let ends = (document.stripsTabs ? line.drop { $0 == "\t" } : line[...]) == document.delimiter
                output += ends || !document.expands ? String(line) : bodyLine(line)
                index = lineEnd < command.endIndex ? command.index(after: lineEnd) : lineEnd
                if lineEnd < command.endIndex {
                    output.append("\n")
                }
                if ends { break }
            }
        }
        pendingHereDocuments.removeAll()
    }

    // A here-document expands variables but never re-reads their values, so the reference goes in bare.
    private func bodyLine(_ line: Substring) -> String {
        var result = ""
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if line[cursor] == "{", cursor == line.startIndex || line[line.index(before: cursor)] != "$",
               let (variable, end) = placeholder(in: line, at: cursor) {
                result += "${\(variable)}"
                cursor = end
                continue
            }
            result.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        return result
    }

    private func placeholder(at start: String.Index) -> (String, String.Index)? {
        placeholder(in: command[...], at: start)
    }

    private func placeholder(in text: Substring, at start: String.Index) -> (String, String.Index)? {
        guard let close = text[start...].firstIndex(of: "}") else { return nil }
        let variable: String
        switch text[text.index(after: start) ..< close] {
        case "host": variable = "TABLEPRO_HOST"
        case "port": variable = "TABLEPRO_PORT"
        case "user": variable = "TABLEPRO_USER"
        case "database": variable = "TABLEPRO_DATABASE"
        default: return nil
        }
        return (variable, text.index(after: close))
    }

    private func follows(_ character: Character, at position: String.Index) -> Bool {
        position > command.startIndex && command[command.index(before: position)] == character
    }

    private func startsWord(at position: String.Index) -> Bool {
        guard position > command.startIndex else { return true }
        let previous = command[command.index(before: position)]
        return previous.isWhitespace || ";|&()`".contains(previous)
    }
}

private enum ShellContext: Equatable {
    case plain
    case single
    case double
    case substitution
    case group
    case backtick

    var isUnquoted: Bool {
        self != .single && self != .double
    }

    func reference(to variable: String) -> String {
        switch self {
        case .single: "'\"${\(variable)}\"'"
        case .double: "${\(variable)}"
        case .plain, .substitution, .group, .backtick: "\"${\(variable)}\""
        }
    }
}

extension ConnectionScriptContext {
    // The host the person typed, not the loopback forward a tunnel puts in its place.
    @MainActor
    init(connection: DatabaseConnection) {
        self.init(
            connectionId: connection.id,
            connectionName: connection.name,
            host: connection.preTunnelHost ?? connection.host,
            port: connection.preTunnelPort ?? connection.port,
            user: ConnectionCredentialResolver.resolveUsername(for: connection),
            database: connection.database
        )
    }
}
