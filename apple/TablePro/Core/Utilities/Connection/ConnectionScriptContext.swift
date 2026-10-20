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
        var output = ""
        var contexts: [ShellContext] = [.plain]
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]
            let next = command.index(after: index)
            let context = contexts.last ?? .plain

            if character == "#", context.startsComments, Self.startsWord(in: command, at: index) {
                let lineEnd = command[index...].firstIndex(of: "\n") ?? command.endIndex
                output += command[index ..< lineEnd]
                index = lineEnd
                continue
            }

            if character == "{", !Self.followsDollar(in: command, at: index),
               let (variable, end) = Self.placeholderVariable(in: command, at: index) {
                output += context.reference(to: variable)
                index = end
                continue
            }

            output.append(character)
            switch character {
            case "\\" where context != .single && next < command.endIndex:
                output.append(command[next])
                index = command.index(after: next)
                continue
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
                continue
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
            index = next
        }
        return output
    }

    private static func placeholderVariable(in command: String, at start: String.Index) -> (String, String.Index)? {
        guard let close = command[start...].firstIndex(of: "}") else { return nil }
        let variable: String
        switch command[command.index(after: start) ..< close] {
        case "host": variable = "TABLEPRO_HOST"
        case "port": variable = "TABLEPRO_PORT"
        case "user": variable = "TABLEPRO_USER"
        case "database": variable = "TABLEPRO_DATABASE"
        default: return nil
        }
        return (variable, command.index(after: close))
    }

    private static func followsDollar(in command: String, at index: String.Index) -> Bool {
        index > command.startIndex && command[command.index(before: index)] == "$"
    }

    private static func startsWord(in command: String, at index: String.Index) -> Bool {
        guard index > command.startIndex else { return true }
        let previous = command[command.index(before: index)]
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

    var startsComments: Bool {
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
