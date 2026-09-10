//
//  TunnelCommandLine.swift
//  TablePro
//

import Foundation

/// Splits a command line into an argument vector without a shell.
///
/// TablePro never hands the command to `/bin/sh -c`. A shell would put itself between TablePro and
/// the process holding the forward, and the signal that ends the tunnel has to reach the forward
/// itself. Quoting is the POSIX subset a command line actually uses, and nothing is expanded: a
/// `$VAR` stays four characters. Someone who wants the shell writes it themselves, as the first
/// word of the command.
enum TunnelCommandLine {
    enum ParseError: Error, Equatable {
        case unbalancedQuote
        case empty
    }

    static let localPortPlaceholder = "{port}"
    static let hostPlaceholder = "{host}"
    static let remotePortPlaceholder = "{remotePort}"

    static func tokenize(_ commandLine: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaping = false

        for character in commandLine {
            if escaping {
                current.append(character)
                hasCurrent = true
                escaping = false
                continue
            }
            if let openQuote = quote {
                if character == openQuote {
                    quote = nil
                } else if openQuote == "\"" && character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                }
                hasCurrent = true
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasCurrent = true
            case "\\":
                escaping = true
            case " ", "\t", "\n", "\r":
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            default:
                current.append(character)
                hasCurrent = true
            }
        }

        if quote != nil || escaping { throw ParseError.unbalancedQuote }
        if hasCurrent { tokens.append(current) }
        guard !tokens.isEmpty else { throw ParseError.empty }
        return tokens.map(expandingTilde)
    }

    /// Runs after tokenization, never before, so a substituted value carrying a space stays one
    /// argument instead of splitting into two.
    static func substitutePlaceholders(
        in tokens: [String],
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) -> [String] {
        tokens.map { token in
            token
                .replacingOccurrences(of: localPortPlaceholder, with: String(localPort))
                .replacingOccurrences(of: hostPlaceholder, with: remoteHost)
                .replacingOccurrences(of: remotePortPlaceholder, with: String(remotePort))
        }
    }

    static func containsLocalPortPlaceholder(_ commandLine: String) -> Bool {
        commandLine.contains(localPortPlaceholder)
    }

    private static func expandingTilde(_ token: String) -> String {
        guard token == "~" || token.hasPrefix("~/") else { return token }
        return (token as NSString).expandingTildeInPath
    }
}
