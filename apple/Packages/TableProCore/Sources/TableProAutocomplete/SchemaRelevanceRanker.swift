import Foundation

public struct SchemaRelevanceDocument: Sendable, Equatable {
    public let name: String
    public let details: [String]

    public init(name: String, details: [String] = []) {
        self.name = name
        self.details = details
    }
}

// Orders tables by how well their names and columns match a question: BM25 over identifier
// words, with trigram matching for words that miss every exact term (typos, inflections).
public enum SchemaRelevanceRanker {
    static let nameWeight = 3
    static let fullNameBoost = 5.0
    static let fuzzyThreshold = 0.5
    static let fuzzyMinLength = 4
    static let k1 = 1.2
    static let b = 0.75

    public static func rank(_ documents: [SchemaRelevanceDocument], for query: String) -> [Int] {
        let queryWords = Set(words(in: query))
        guard !queryWords.isEmpty, !documents.isEmpty else { return [] }

        let index = Index(documents: documents)
        let matches = queryWords.flatMap { index.matches(for: $0) }
        let orderedQueryWords = words(in: query)

        var scored: [(offset: Int, score: Double)] = []
        for (offset, terms) in index.termCounts.enumerated() {
            var score = 0.0
            for match in matches {
                guard let frequency = terms[match.term] else { continue }
                score += match.weight * index.bm25(frequency: frequency, idfTerm: match.term, length: index.lengths[offset])
            }
            let nameWords = index.nameWords[offset]
            if nameWords.joined().count >= fuzzyMinLength, containsSequence(orderedQueryWords, nameWords) {
                score += fullNameBoost
            }
            if score > 0 {
                scored.append((offset, score))
            }
        }

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.offset)
    }

    private static func containsSequence(_ words: [String], _ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, words.count >= sequence.count else { return false }
        return (0...(words.count - sequence.count)).contains { start in
            Array(words[start..<(start + sequence.count)]) == sequence
        }
    }

    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?

        func flush() {
            if !current.isEmpty {
                result.append(stem(current))
                current = ""
            }
        }

        for character in text {
            guard character.isLetter || character.isNumber else {
                flush()
                previous = nil
                continue
            }
            if let previous, startsNewWord(previous: previous, current: character) {
                flush()
            }
            current += fold(character)
            previous = character
        }
        flush()
        return result
    }

    // Folding leaves "đ" alone because Unicode treats it as its own letter, not a "d" with a mark.
    private static func fold(_ character: Character) -> String {
        if character == "đ" || character == "Đ" { return "d" }
        return String(character).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    private static func startsNewWord(previous: Character, current: Character) -> Bool {
        if previous.isLowercase, current.isUppercase { return true }
        if previous.isLetter, current.isNumber { return true }
        if previous.isNumber, current.isLetter { return true }
        return false
    }

    static func stem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy(\.isASCII) else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    static func trigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        trigramSimilarity(trigrams(lhs), trigrams(rhs))
    }

    private static func trigramSimilarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func trigrams(_ word: String) -> Set<String> {
        let padded = Array("  \(word) ")
        guard padded.count >= 3 else { return [] }
        return Set((0...(padded.count - 3)).map { String(padded[$0..<($0 + 3)]) })
    }

    private struct Match {
        let term: String
        let weight: Double
    }

    private struct Index {
        let termCounts: [[String: Int]]
        let nameWords: [[String]]
        let lengths: [Int]
        let documentFrequency: [String: Int]
        let fuzzyTerms: [(term: String, trigrams: Set<String>)]
        let averageLength: Double

        init(documents: [SchemaRelevanceDocument]) {
            var termCounts: [[String: Int]] = []
            var nameWords: [[String]] = []
            var lengths: [Int] = []
            var documentFrequency: [String: Int] = [:]
            termCounts.reserveCapacity(documents.count)

            for document in documents {
                let name = SchemaRelevanceRanker.words(in: document.name)
                var counts: [String: Int] = [:]
                for word in name {
                    counts[word, default: 0] += SchemaRelevanceRanker.nameWeight
                }
                for detail in document.details {
                    for word in SchemaRelevanceRanker.words(in: detail) {
                        counts[word, default: 0] += 1
                    }
                }
                for term in counts.keys {
                    documentFrequency[term, default: 0] += 1
                }
                termCounts.append(counts)
                nameWords.append(name)
                lengths.append(counts.values.reduce(0, +))
            }

            self.termCounts = termCounts
            self.nameWords = nameWords
            self.lengths = lengths
            self.documentFrequency = documentFrequency
            self.fuzzyTerms = documentFrequency.keys
                .filter { $0.count >= SchemaRelevanceRanker.fuzzyMinLength }
                .map { ($0, SchemaRelevanceRanker.trigrams($0)) }
            let total = lengths.reduce(0, +)
            self.averageLength = documents.isEmpty ? 0 : max(Double(total) / Double(documents.count), 1)
        }

        func matches(for word: String) -> [Match] {
            if documentFrequency[word] != nil {
                return [Match(term: word, weight: 1)]
            }
            guard word.count >= SchemaRelevanceRanker.fuzzyMinLength else { return [] }
            let wordTrigrams = SchemaRelevanceRanker.trigrams(word)
            return fuzzyTerms.compactMap { entry in
                let similarity = SchemaRelevanceRanker.trigramSimilarity(wordTrigrams, entry.trigrams)
                return similarity >= SchemaRelevanceRanker.fuzzyThreshold ? Match(term: entry.term, weight: similarity) : nil
            }
        }

        func bm25(frequency: Int, idfTerm: String, length: Int) -> Double {
            let documentCount = Double(termCounts.count)
            let containing = Double(documentFrequency[idfTerm] ?? 0)
            let idf = log(1 + (documentCount - containing + 0.5) / (containing + 0.5))
            let tf = Double(frequency)
            let k1 = SchemaRelevanceRanker.k1
            let b = SchemaRelevanceRanker.b
            let norm = k1 * (1 - b + b * Double(length) / averageLength)
            return idf * (tf * (k1 + 1)) / (tf + norm)
        }
    }
}
