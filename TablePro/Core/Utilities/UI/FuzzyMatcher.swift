//
//  FuzzyMatcher.swift
//  TablePro
//
//  Standalone fuzzy matching utility for quick switcher search
//

import Foundation

/// Namespace for fuzzy string matching operations
internal enum FuzzyMatcher {
    /// Score a candidate string against a search query.
    /// Returns 0 for no match, higher values indicate better matches.
    /// Empty query returns 1 (everything matches).
    static func score(query: String, candidate: String) -> Int {
        let queryScalars = Array(query.unicodeScalars)
        let candidateScalars = Array(candidate.unicodeScalars)
        let queryLen = queryScalars.count
        let candidateLen = candidateScalars.count

        if queryLen == 0 { return 1 }
        if candidateLen == 0 { return 0 }

        var score = 0
        var queryIndex = 0
        var candidateIndex = 0
        var consecutiveBonus = 0
        var firstMatchPosition = -1

        while candidateIndex < candidateLen, queryIndex < queryLen {
            let queryChar = Character(queryScalars[queryIndex])
            let candidateChar = Character(candidateScalars[candidateIndex])

            guard queryChar.lowercased() == candidateChar.lowercased() else {
                candidateIndex += 1
                consecutiveBonus = 0
                continue
            }

            // Base match score
            var matchScore = 1

            // Record first match position
            if firstMatchPosition < 0 {
                firstMatchPosition = candidateIndex
            }

            // Consecutive match bonus
            consecutiveBonus += 1
            if consecutiveBonus > 1 {
                matchScore += consecutiveBonus * 4
            }

            // Word boundary bonus
            if candidateIndex == 0 {
                matchScore += 10
            } else {
                let prevChar = Character(candidateScalars[candidateIndex - 1])
                if prevChar == " " || prevChar == "_" || prevChar == "." || prevChar == "-" {
                    matchScore += 8
                    consecutiveBonus = 1
                } else if prevChar.isLowercase && candidateChar.isUppercase {
                    matchScore += 6
                    consecutiveBonus = 1
                }
            }

            // Exact case match bonus
            if queryChar == candidateChar {
                matchScore += 1
            }

            score += matchScore
            queryIndex += 1
            candidateIndex += 1
        }

        // All query characters must be matched
        guard queryIndex == queryLen else { return 0 }

        // Position bonus
        if firstMatchPosition >= 0 {
            let positionBonus = max(0, 20 - firstMatchPosition * 2)
            score += positionBonus
        }

        // Length similarity bonus
        let lengthRatio = Double(queryLen) / Double(candidateLen)
        score += Int(lengthRatio * 10)

        return score
    }
}
