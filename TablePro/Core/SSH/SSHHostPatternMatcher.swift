//
//  SSHHostPatternMatcher.swift
//  TablePro
//

import Darwin
import Foundation

/// Pattern list matching mirrors OpenSSH's `match_pattern_list`: a host
/// matches iff at least one positive pattern matches AND no negative pattern
/// matches. Globs are evaluated via POSIX `fnmatch(3)`, the same primitive
/// OpenSSH uses.
enum SSHHostPatternMatcher {
    static func matches(host: String, patterns: [HostPattern]) -> Bool {
        guard !patterns.isEmpty else { return false }

        var hasPositiveMatch = false
        for pattern in patterns {
            guard fnmatch(pattern.glob, host) else { continue }

            if pattern.negated {
                return false
            }
            hasPositiveMatch = true
        }
        return hasPositiveMatch
    }

    static func parsePatternList(_ value: String) -> [HostPattern] {
        let separators = CharacterSet(charactersIn: ", \t")
        return value
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
