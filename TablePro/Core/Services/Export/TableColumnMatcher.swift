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
    }

    /// Case-insensitive, because engines disagree about identifier folding and a transfer from a
    /// case-folding engine to a case-preserving one would otherwise match nothing.
    static func match(source: [String], destination: [String]) -> Match {
        var destinationByFolded: [String: String] = [:]
        for column in destination {
            destinationByFolded[column.lowercased()] = column
        }

        var mapping: [String: String] = [:]
        var unmatchedSource: [String] = []
        var claimed: Set<String> = []
        for column in source {
            guard let target = destinationByFolded[column.lowercased()] else {
                unmatchedSource.append(column)
                continue
            }
            mapping[column] = target
            claimed.insert(target)
        }
        return Match(
            mapping: mapping,
            unmatchedSource: unmatchedSource,
            unmatchedDestination: destination.filter { !claimed.contains($0) }
        )
    }

    /// Applies the user's overrides over an automatic match. An override to nil excludes the
    /// column, which is how a source column with no destination is deliberately dropped rather
    /// than failing the transfer.
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
}
