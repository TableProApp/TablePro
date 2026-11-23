import Foundation

public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    public let matchedIndices: [Int]
}

/// A query split into characters and folded once, so ranking a catalog against it does not redo
/// that work for every candidate.
public struct FuzzyQuery: Sendable {
    public let text: String
    fileprivate let characters: [Character]
    fileprivate let foldedCharacters: [String]
    /// Nil when a byte of the query is not one `Character` on its own: anything at or above 0x80,
    /// and a carriage return, which joins a following line feed.
    fileprivate let bytes: [UInt8]?
    fileprivate let foldedBytes: [UInt8]?

    public init(_ text: String) {
        self.text = text
        characters = Array(text)
        foldedCharacters = characters.map { $0.lowercased() }
        let utf8 = Array(text.utf8)
        if utf8.allSatisfy(FuzzyMatcher.isSingleCharacterByte) {
            bytes = utf8
            foldedBytes = utf8.map(FuzzyMatcher.foldedByte)
        } else {
            bytes = nil
            foldedBytes = nil
        }
    }
}

/// Rows the scorer reuses from one candidate to the next, so a ranking pass allocates them once.
public struct FuzzyScratch {
    fileprivate var previousMatch: [Int] = []
    fileprivate var previousBest: [Int] = []
    fileprivate var currentMatch: [Int] = []
    fileprivate var currentBest: [Int] = []
    fileprivate var bonuses: [Int] = []

    public init() {}

    fileprivate mutating func reserve(_ count: Int) {
        guard bonuses.count < count else { return }
        // Every cell a candidate reads is written first, so the starting value does not matter.
        let row = [Int](repeating: 0, count: count)
        previousMatch = row
        previousBest = row
        currentMatch = row
        currentBest = row
        bonuses = row
    }
}

public enum FuzzyMatcher {
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

    public static func matches(query: String, candidate: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return match(query: trimmed, candidate: candidate) != nil
    }

    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        let queryChars = Array(query)
        return characterMatch(
            queryChars: queryChars,
            foldedQuery: queryChars.map { $0.lowercased() },
            candidateChars: Array(candidate),
            withIndices: true
        )
    }

    /// The score `match(query:candidate:)` gives, without the matched indices. An ASCII query and
    /// candidate are scored over their bytes with two reused rows, which is what ranking a whole
    /// catalog per keystroke needs; anything else takes the `Character` path.
    public static func score(_ query: FuzzyQuery, _ candidate: String, scratch: inout FuzzyScratch) -> Int? {
        if let queryBytes = query.bytes, let foldedQuery = query.foldedBytes {
            let outcome = candidate.utf8.withContiguousStorageIfAvailable { candidateBytes in
                asciiScore(queryBytes: queryBytes, foldedQuery: foldedQuery, candidate: candidateBytes, scratch: &scratch)
            }
            switch outcome {
            case .scored(let score)?:
                return score
            case .needsCharacters?:
                break
            case nil:
                var contiguous = candidate
                contiguous.makeContiguousUTF8()
                return score(query, contiguous, scratch: &scratch)
            }
        }
        return characterMatch(
            queryChars: query.characters,
            foldedQuery: query.foldedCharacters,
            candidateChars: Array(candidate),
            withIndices: false
        )?.score
    }

    private static func characterMatch(
        queryChars: [Character],
        foldedQuery: [String],
        candidateChars: [Character],
        withIndices: Bool
    ) -> FuzzyMatch? {
        guard !queryChars.isEmpty, !candidateChars.isEmpty, queryChars.count <= candidateChars.count else {
            return nil
        }
        if candidateChars.count > maxScoredCandidateLength || queryChars.count > maxScoredQueryLength {
            return greedyMatch(queryChars: queryChars, foldedQuery: foldedQuery, candidateChars: candidateChars)
        }
        return optimalMatch(
            queryChars: queryChars,
            foldedQuery: foldedQuery,
            candidateChars: candidateChars,
            withIndices: withIndices
        )
    }

    private static func optimalMatch(
        queryChars: [Character],
        foldedQuery: [String],
        candidateChars: [Character],
        withIndices: Bool
    ) -> FuzzyMatch? {
        let queryLength = queryChars.count
        let candidateLength = candidateChars.count
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
        guard withIndices else { return FuzzyMatch(score: finalScore, matchedIndices: []) }

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

    private static func greedyMatch(
        queryChars: [Character],
        foldedQuery: [String],
        candidateChars: [Character]
    ) -> FuzzyMatch? {
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

    private enum ASCIIOutcome {
        case scored(Int?)
        case needsCharacters
    }

    // Same recurrence as `optimalMatch`, one byte per `Character`, keeping only the previous row.
    private static func asciiScore(
        queryBytes: [UInt8],
        foldedQuery: [UInt8],
        candidate: UnsafeBufferPointer<UInt8>,
        scratch: inout FuzzyScratch
    ) -> ASCIIOutcome {
        let queryLength = queryBytes.count
        let candidateLength = candidate.count
        var matchedPrefix = 0
        for byte in candidate {
            guard isSingleCharacterByte(byte) else { return .needsCharacters }
            if matchedPrefix < queryLength, foldedByte(byte) == foldedQuery[matchedPrefix] {
                matchedPrefix += 1
            }
        }
        guard queryLength > 0, candidateLength > 0, queryLength <= candidateLength else { return .scored(nil) }
        if candidateLength > maxScoredCandidateLength || queryLength > maxScoredQueryLength {
            return .needsCharacters
        }
        guard matchedPrefix == queryLength else { return .scored(nil) }

        scratch.reserve(candidateLength)
        for index in 0..<candidateLength {
            scratch.bonuses[index] = asciiBoundaryBonus(at: index, in: candidate)
        }

        for queryIndex in 0..<queryLength {
            let foldedQueryByte = foldedQuery[queryIndex]
            let queryByte = queryBytes[queryIndex]
            var runningGapScore = invalid
            for candidateIndex in 0..<candidateLength {
                var matchScore = invalid
                let candidateByte = candidate[candidateIndex]
                if foldedQueryByte == foldedByte(candidateByte) {
                    let base: Int
                    if queryIndex == 0 {
                        base = leadingGapPenalty(for: candidateIndex) + scratch.bonuses[candidateIndex]
                    } else if candidateIndex > 0 {
                        let viaBoundary = scratch.previousBest[candidateIndex - 1] + scratch.bonuses[candidateIndex]
                        let viaConsecutive = scratch.previousMatch[candidateIndex - 1] + Weight.consecutive
                        base = max(viaBoundary, viaConsecutive)
                    } else {
                        base = invalid
                    }
                    if isValid(base) {
                        matchScore = base + Weight.match + (queryByte == candidateByte ? Weight.exactCase : 0)
                    }
                }

                scratch.currentMatch[candidateIndex] = matchScore

                if candidateIndex > 0 {
                    let previousMatch = scratch.currentMatch[candidateIndex - 1]
                    let opened = isValid(previousMatch) ? previousMatch + Weight.gapOpen : invalid
                    let extended = isValid(runningGapScore) ? runningGapScore + Weight.gapExtension : invalid
                    runningGapScore = max(opened, extended)
                } else {
                    runningGapScore = invalid
                }

                scratch.currentBest[candidateIndex] = max(matchScore, runningGapScore)
            }
            swap(&scratch.previousMatch, &scratch.currentMatch)
            swap(&scratch.previousBest, &scratch.currentBest)
        }

        let finalScore = scratch.previousBest[candidateLength - 1]
        return .scored(isValid(finalScore) ? finalScore : nil)
    }

    private static func asciiBoundaryBonus(at index: Int, in candidate: UnsafeBufferPointer<UInt8>) -> Int {
        guard index > 0 else { return Weight.firstCharacter }
        let previous = candidate[index - 1]
        if separatorBytes.contains(previous) {
            return Weight.separatorBoundary
        }
        if isLowercaseASCII(previous), isUppercaseASCII(candidate[index]) {
            return Weight.camelBoundary
        }
        return 0
    }

    // The bytes of `separators`, in the order a table name holds them most.
    private static let separatorBytes: [UInt8] = [0x5F, 0x2E, 0x20, 0x2D, 0x2F, 0x24]

    fileprivate static func isSingleCharacterByte(_ byte: UInt8) -> Bool {
        byte < 0x80 && byte != 0x0D
    }

    fileprivate static func foldedByte(_ byte: UInt8) -> UInt8 {
        isUppercaseASCII(byte) ? byte | 0x20 : byte
    }

    private static func isUppercaseASCII(_ byte: UInt8) -> Bool {
        byte >= 0x41 && byte <= 0x5A
    }

    private static func isLowercaseASCII(_ byte: UInt8) -> Bool {
        byte >= 0x61 && byte <= 0x7A
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
