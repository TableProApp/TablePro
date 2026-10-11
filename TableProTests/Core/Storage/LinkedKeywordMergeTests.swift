//
//  LinkedKeywordMergeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Two linked `.sql` files may declare the same keyword, and nothing stops them: the files are
/// edited outside the app and the index holds no uniqueness. Which one the keyword reached used to
/// be decided by whichever disk read finished first, so it changed between launches.
struct LinkedKeywordMergeTests {
    private func candidate(
        keyword: String = "daily",
        name: String = "Daily",
        query: String,
        folderRank: Int = 0,
        relativePath: String
    ) -> LinkedKeywordCandidate {
        LinkedKeywordCandidate(
            keyword: keyword,
            name: name,
            query: query,
            folderRank: folderRank,
            relativePath: relativePath
        )
    }

    @Test("The folder linked first wins a keyword two folders claim")
    func theEarlierFolderWins() {
        let first = candidate(query: "SELECT 1", folderRank: 0, relativePath: "daily.sql")
        let second = candidate(query: "SELECT 2", folderRank: 1, relativePath: "daily.sql")

        #expect(SQLFavoriteManager.mergeLinkedKeywords([second, first])["daily"]?.query == "SELECT 1")
        #expect(SQLFavoriteManager.mergeLinkedKeywords([first, second])["daily"]?.query == "SELECT 1")
    }

    @Test("Inside one folder the earlier path wins a keyword two files claim")
    func theEarlierPathWins() {
        let archive = candidate(query: "SELECT archived", relativePath: "archive/daily.sql")
        let reports = candidate(query: "SELECT current", relativePath: "reports/daily.sql")

        #expect(SQLFavoriteManager.mergeLinkedKeywords([reports, archive])["daily"]?.query == "SELECT archived")
        #expect(SQLFavoriteManager.mergeLinkedKeywords([archive, reports])["daily"]?.query == "SELECT archived")
    }

    /// The order the reads finish in is the order the candidates arrive in, so the merge has to
    /// give the same answer for every permutation or the keyword changes between launches.
    @Test("Every arrival order gives the same answer")
    func theResultDoesNotDependOnArrivalOrder() {
        let candidates = [
            candidate(query: "A", folderRank: 0, relativePath: "b.sql"),
            candidate(query: "B", folderRank: 0, relativePath: "a.sql"),
            candidate(query: "C", folderRank: 1, relativePath: "a.sql")
        ]

        let answers = Set(permutations(of: candidates).map { SQLFavoriteManager.mergeLinkedKeywords($0)["daily"]?.query })

        #expect(answers == ["B"])
    }

    @Test("Keywords claimed by one file each are all kept")
    func distinctKeywordsAreAllKept() {
        let merged = SQLFavoriteManager.mergeLinkedKeywords([
            candidate(keyword: "daily", query: "SELECT 1", relativePath: "daily.sql"),
            candidate(keyword: "weekly", query: "SELECT 2", relativePath: "weekly.sql")
        ])

        #expect(merged.count == 2)
        #expect(merged["weekly"]?.query == "SELECT 2")
    }

    @Test("No files claim nothing")
    func anEmptyListMergesToNothing() {
        #expect(SQLFavoriteManager.mergeLinkedKeywords([]).isEmpty)
    }

    private func permutations(of candidates: [LinkedKeywordCandidate]) -> [[LinkedKeywordCandidate]] {
        guard candidates.count > 1 else { return [candidates] }
        var result: [[LinkedKeywordCandidate]] = []
        for index in candidates.indices {
            var rest = candidates
            let picked = rest.remove(at: index)
            for tail in permutations(of: rest) {
                result.append([picked] + tail)
            }
        }
        return result
    }
}
