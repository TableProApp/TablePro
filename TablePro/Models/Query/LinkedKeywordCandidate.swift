//
//  LinkedKeywordCandidate.swift
//  TablePro
//

import Foundation

/// One linked `.sql` file's claim on a keyword, carrying where the file sits so two claims on the
/// same keyword can be settled by something the user can see.
internal struct LinkedKeywordCandidate: Sendable, Equatable {
    internal let keyword: String
    internal let name: String
    internal let query: String
    internal let folderRank: Int
    internal let relativePath: String

    internal static func precedes(_ lhs: LinkedKeywordCandidate, _ rhs: LinkedKeywordCandidate) -> Bool {
        if lhs.folderRank != rhs.folderRank { return lhs.folderRank < rhs.folderRank }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}
