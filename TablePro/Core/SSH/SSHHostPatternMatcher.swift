//
//  SSHHostPatternMatcher.swift
//  TablePro
//

import Darwin
import Foundation

/// Pattern list matching mirrors OpenSSH's `match_pattern_list`: a host matches iff at least one
/// positive pattern matches AND no negative pattern matches. Globs are evaluated via POSIX
/// `fnmatch(3)`, the same primitive OpenSSH uses.
///
/// The two constructs that take a pattern list do not agree on how it is written, measured against
/// OpenSSH 10.3: a `Host` line is a whitespace-separated list matched case-sensitively, so
/// `Host a,b` matches neither `a` nor `b` and the comma is an ordinary character. A `Match host`
/// argument is a single comma-separated list matched case-insensitively, and whitespace there
/// starts the next criterion instead.
enum SSHHostPatternMatcher {
    static func matches(host: String, patterns: [HostPattern], caseSensitive: Bool = true) -> Bool {
        guard !patterns.isEmpty else { return false }

        let subject = caseSensitive ? host : host.lowercased()
        var hasPositiveMatch = false
        for pattern in patterns {
            let glob = caseSensitive ? pattern.glob : pattern.glob.lowercased()
            guard fnmatch(glob, subject) else { continue }

            if pattern.negated {
                return false
            }
            hasPositiveMatch = true
        }
        return hasPositiveMatch
    }

    /// The list on a `Host` line, separated by whitespace only.
    static func parseHostPatternList(_ value: String) -> [HostPattern] {
        parse(value, separators: CharacterSet(charactersIn: " \t"))
    }

    /// The argument to a `Match host` criterion, separated by commas only.
    static func parseMatchPatternList(_ value: String) -> [HostPattern] {
        parse(value, separators: CharacterSet(charactersIn: ","))
    }

    private static func parse(_ value: String, separators: CharacterSet) -> [HostPattern] {
        value
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { token in
                if token.hasPrefix("!") {
                    return HostPattern(glob: String(token.dropFirst()), negated: true)
                }
                return HostPattern(glob: token, negated: false)
            }
    }

    private static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        pattern.withCString { patternPtr in
            name.withCString { namePtr in
                Darwin.fnmatch(patternPtr, namePtr, 0) == 0
            }
        }
    }
}
