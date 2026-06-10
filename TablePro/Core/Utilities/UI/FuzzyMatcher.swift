//
//  FuzzyMatcher.swift
//  TablePro
//

import Foundation

internal struct FuzzyMatch: Equatable, Sendable {
    let score: Int
    let matchedIndices: [Int]
}

internal enum FuzzyMatcher {
    private enum Weight {
        static let match = 16
        static let consecutive = 24
        static let firstCharacter = 28
        static let separatorBoundary = 20
        static let camelBoundary = 18
        static let exactCase = 1
        static let gapOpen = -3
        static let gapExtension = -1
        static let leadingGapExtension = -1
        static let leadingGapFloor = -8
    }

    private static let separators: Set<Character> = [" ", "_", "-", ".", "/", "$"]
    private static let maxScoredCandidateLength = 1_024
    private static let maxScoredQueryLength = 64
    private static let invalid = Int.min / 4

    static func matches(query: String, candidate: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return match(query: trimmed, candidate: candidate) != nil
    }

    static func match(query: String, candidate: String) -> FuzzyMatch? {
        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        guard !queryChars.isEmpty, !candidateChars.isEmpty, queryChars.count <= candidateChars.count else {
            return nil
        }
        if candidateChars.count > maxScoredCandidateLength || queryChars.count > maxScoredQueryLength {
            return greedyMatch(queryChars: queryChars, candidateChars: candidateChars)
        }
        return optimalMatch(queryChars: queryChars, candidateChars: candidateChars)
    }

    private static func optimalMatch(queryChars: [Character], candidateChars: [Character]) -> FuzzyMatch? {
        let queryLength = queryChars.count
        let candidateLength = candidateChars.count
        let foldedQuery = queryChars.map { $0.lowercased() }
        let foldedCandidate = candidateChars.map { $0.lowercased() }
        let bonuses = boundaryBonuses(for: candidateChars)

        var matchScores = [Int](repeating: invalid, count: queryLength * candidateLength)
        var bestScores = [Int](repeating: invalid, count: queryLength * candidateLength)

        for queryIndex in 0..<queryLength {
            var runningGapScore = invalid
            for candidateIndex in 0..<candidateLength {
                let cell = queryIndex * candidateLength + candidateIndex
                var matchScore = invalid

                if foldedQuery[queryIndex] == foldedCandidate[candidateIndex] {
                    let base: Int
                    if queryIndex == 0 {
                        base = leadingGapPenalty(for: candidateIndex) + bonuses[candidateIndex]
                    } else if candidateIndex > 0 {
                        let diagonal = cell - candidateLength - 1
                        let viaBoundary = bestScores[diagonal] + bonuses[candidateIndex]
                        let viaConsecutive = matchScores[diagonal] + Weight.consecutive
                        base = max(viaBoundary, viaConsecutive)
                    } else {
                        base = invalid
                    }
                    if isValid(base) {
                        let caseBonus = queryChars[queryIndex] == candidateChars[candidateIndex]
                            ? Weight.exactCase
                            : 0
                        matchScore = base + Weight.match + caseBonus
                    }
                }

                matchScores[cell] = matchScore

                if candidateIndex > 0 {
                    let previousMatch = matchScores[cell - 1]
                    let opened = isValid(previousMatch) ? previousMatch + Weight.gapOpen : invalid
                    let extended = isValid(runningGapScore) ? runningGapScore + Weight.gapExtension : invalid
                    runningGapScore = max(opened, extended)
                } else {
                    runningGapScore = invalid
                }

                bestScores[cell] = max(matchScore, runningGapScore)
            }
        }

        let finalScore = bestScores[queryLength * candidateLength - 1]
        guard isValid(finalScore) else { return nil }

        let indices = traceback(
            queryChars: queryChars,
            candidateChars: candidateChars,
            matchScores: matchScores,
            bestScores: bestScores
        )
        return FuzzyMatch(score: finalScore, matchedIndices: indices)
    }

    private static func traceback(
        queryChars: [Character],
        candidateChars: [Character],
        matchScores: [Int],
        bestScores: [Int]
    ) -> [Int] {
        let queryLength = queryChars.count
        let candidateLength = candidateChars.count
        var indices = [Int](repeating: 0, count: queryLength)
        var queryIndex = queryLength - 1
        var candidateIndex = candidateLength - 1
        var matchRequired = false

        while queryIndex >= 0, candidateIndex >= 0 {
            var cell = queryIndex * candidateLength + candidateIndex
            while !matchRequired, candidateIndex > 0, matchScores[cell] != bestScores[cell] {
                candidateIndex -= 1
                cell -= 1
            }
            indices[queryIndex] = candidateIndex
            if queryIndex > 0, candidateIndex > 0 {
                let caseBonus = queryChars[queryIndex] == candidateChars[candidateIndex]
                    ? Weight.exactCase
                    : 0
                let diagonal = cell - candidateLength - 1
                matchRequired = matchScores[cell] == matchScores[diagonal] + Weight.consecutive + Weight.match + caseBonus
            }
            queryIndex -= 1
            candidateIndex -= 1
        }
        return indices
    }

    private static func greedyMatch(queryChars: [Character], candidateChars: [Character]) -> FuzzyMatch? {
        let foldedQuery = queryChars.map { $0.lowercased() }
        var score = 0
        var indices: [Int] = []
        indices.reserveCapacity(queryChars.count)
        var queryIndex = 0
        var lastMatchIndex = -2

        for (candidateIndex, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count else { break }
            guard character.lowercased() == foldedQuery[queryIndex] else { continue }

            var matchScore = Weight.match + boundaryBonus(at: candidateIndex, in: candidateChars)
            if candidateIndex == lastMatchIndex + 1 {
                matchScore += Weight.consecutive
            }
            if queryChars[queryIndex] == character {
                matchScore += Weight.exactCase
            }
            if indices.isEmpty {
                score += leadingGapPenalty(for: candidateIndex)
            } else {
                let gap = candidateIndex - lastMatchIndex - 1
                if gap > 0 {
                    score += Weight.gapOpen + Weight.gapExtension * (gap - 1)
                }
            }
            score += matchScore
            indices.append(candidateIndex)
            lastMatchIndex = candidateIndex
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        return FuzzyMatch(score: score, matchedIndices: indices)
    }

    private static func boundaryBonuses(for candidateChars: [Character]) -> [Int] {
        candidateChars.indices.map { boundaryBonus(at: $0, in: candidateChars) }
    }

    private static func boundaryBonus(at index: Int, in candidateChars: [Character]) -> Int {
        guard index > 0 else { return Weight.firstCharacter }
        let previous = candidateChars[index - 1]
        if separators.contains(previous) {
            return Weight.separatorBoundary
        }
        if previous.isLowercase, candidateChars[index].isUppercase {
            return Weight.camelBoundary
        }
        return 0
    }

    private static func leadingGapPenalty(for firstMatchIndex: Int) -> Int {
        max(Weight.leadingGapFloor, Weight.leadingGapExtension * firstMatchIndex)
    }

    private static func isValid(_ score: Int) -> Bool {
        score > invalid / 2
    }
}
