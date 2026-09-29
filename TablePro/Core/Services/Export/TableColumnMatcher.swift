//
//  TableColumnMatcher.swift
//  TablePro
//

import Foundation

/// Matches a source table's columns to a destination table's, by name.
///
/// The import sink writes by column name and skips any field the mapping does not name, so an empty
/// mapping writes nothing and reports every row as unmapped. That is what a transfer with no
/// mapping did: it failed on the first batch of every table.
enum TableColumnMatcher {
    struct Match: Equatable {
        /// Source column to destination column, keyed as the sink keys it.
        let mapping: [String: String]

        /// Source columns with no destination of that name. Reported before the transfer starts
        /// rather than surfacing as a row that silently loses a value.
        let unmatchedSource: [String]

        /// Destination columns nothing maps onto. They take their own default or null, which is
        /// only a problem when one is `NOT NULL` without a default, so it is reported rather than
        /// refused.
        let unmatchedDestination: [String]

        var isEmpty: Bool { mapping.isEmpty }

        /// Destination columns more than one source column is mapped to. The INSERT would name
        /// each of them twice, which every engine refuses, so the transfer cannot run until the
        /// user moves one.
        var contestedDestinations: [String] {
            TableColumnMatcher.contestedDestinations(in: mapping)
        }
    }

    /// Exact spelling first, then case-insensitive, because engines disagree about identifier
    /// folding and a transfer from a case-folding engine to a case-preserving one would otherwise
    /// match nothing. A destination column goes to one source column at most, so `Name` and `name`
    /// on the source never both land on a lone `name`.
    static func match(source: [String], destination: [String]) -> Match {
        let targets = pair(source, with: destination)
        var mapping: [String: String] = [:]
        var unmatchedSource: [String] = []
        for (column, target) in zip(source, targets) {
            guard let target else {
                unmatchedSource.append(column)
                continue
            }
            mapping[column] = target
        }
        let claimed = Set(mapping.values)
        return Match(
            mapping: mapping,
            unmatchedSource: unmatchedSource,
            unmatchedDestination: destination.filter { !claimed.contains($0) }
        )
    }

    /// The automatic match with the user's overrides laid over it.
    static func match(
        source: [String],
        destination: [String],
        overrides: [String: String?]
    ) -> Match {
        let automatic = match(source: source, destination: destination)
        guard !overrides.isEmpty else { return automatic }
        return applying(overrides: overrides, to: automatic, destination: destination)
    }

    /// Applies the user's overrides over an automatic match. An override to nil excludes the
    /// column, which is how a source column with no destination is deliberately dropped rather
    /// than failing the transfer. An override may point at a column another source column
    /// already holds; that is kept and reported through `contestedDestinations`, not resolved
    /// by quietly unmapping the other one.
    static func applying(
        overrides: [String: String?],
        to match: Match,
        destination: [String]
    ) -> Match {
        var mapping = match.mapping
        var unmatchedSource = Set(match.unmatchedSource)
        for (sourceColumn, target) in overrides {
            guard let target, destination.contains(target) else {
                mapping.removeValue(forKey: sourceColumn)
                unmatchedSource.insert(sourceColumn)
                continue
            }
            mapping[sourceColumn] = target
            unmatchedSource.remove(sourceColumn)
        }
        let claimed = Set(mapping.values)
        return Match(
            mapping: mapping,
            unmatchedSource: unmatchedSource.sorted(),
            unmatchedDestination: destination.filter { !claimed.contains($0) }
        )
    }

    /// Destination columns named by more than one entry of `mapping`, sorted.
    static func contestedDestinations(in mapping: [String: String]) -> [String] {
        var sourceCount: [String: Int] = [:]
        for target in mapping.values {
            sourceCount[target, default: 0] += 1
        }
        return sourceCount.filter { $0.value > 1 }.keys.sorted()
    }

    /// Pairs each name with a candidate of the same spelling, then with a candidate left over that
    /// differs only by case, earlier names first. A candidate is paired with one name at most.
    private static func pair(_ names: [String], with candidates: [String]) -> [String?] {
        var pairs = [String?](repeating: nil, count: names.count)
        var claimed = Set<String>()
        let spelled = Set(candidates)
        for (index, name) in names.enumerated() {
            guard spelled.contains(name), !claimed.contains(name) else { continue }
            pairs[index] = name
            claimed.insert(name)
        }

        var unclaimedByFolded: [String: [String]] = [:]
        for candidate in candidates where !claimed.contains(candidate) {
            unclaimedByFolded[candidate.lowercased(), default: []].append(candidate)
        }
        for (index, name) in names.enumerated() where pairs[index] == nil {
            let folded = name.lowercased()
            guard var remaining = unclaimedByFolded[folded], !remaining.isEmpty else { continue }
            pairs[index] = remaining.removeFirst()
            unclaimedByFolded[folded] = remaining
        }
        return pairs
    }
}
