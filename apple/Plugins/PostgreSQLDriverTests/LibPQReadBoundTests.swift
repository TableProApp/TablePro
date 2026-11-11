//
//  LibPQReadBoundTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQReadBoundTests {
    @Test("No row cap and no byte limit leaves the read whole")
    func noBoundReadsWhole() {
        #expect(LibPQReadBound.ifSet(rowCap: nil, byteLimit: nil) == nil)
        #expect(LibPQReadBound.ifSet(rowCap: 0, byteLimit: nil) == nil)
        #expect(LibPQReadBound.ifSet(rowCap: -5, byteLimit: nil) == nil)
    }

    @Test("A byte limit alone bounds the rows at the emergency maximum")
    func byteLimitAloneKeepsTheEmergencyCap() {
        let bound = LibPQReadBound.ifSet(rowCap: nil, byteLimit: 4_096)

        #expect(bound == LibPQReadBound(rowCap: PluginRowLimits.emergencyMax, byteLimit: 4_096))
    }

    @Test("The read stops at the row past the cap")
    func stopsPastTheCap() {
        let bound = LibPQReadBound(rowCap: 3, byteLimit: nil)

        #expect(!bound.isReached(rows: 3, bytes: .max))
        #expect(bound.isReached(rows: 4, bytes: 0))
    }

    @Test("The read stops at the first row that takes it past the byte limit, not at the one that reaches it")
    func stopsPastTheByteLimit() {
        let bound = LibPQReadBound(rowCap: 1_000, byteLimit: 250)

        #expect(!bound.isReached(rows: 2, bytes: 250))
        #expect(bound.isReached(rows: 3, bytes: 251))
    }

    @Test("Only the row that told 'more' is dropped; a row that crossed the byte limit is kept")
    func keepsTheCrossingRow() {
        let bound = LibPQReadBound(rowCap: 3, byteLimit: 10)
        let three: [[PluginCellValue]] = [[.text("a")], [.text("b")], [.text("c")]]
        let four = three + [[.text("d")]]

        #expect(bound.kept(three) == three)
        #expect(bound.kept(four) == three)
    }

    @Test("A row's size is its text in UTF-8 and its bytes, with nulls free")
    func measuresDecodedSize() {
        let row: [PluginCellValue] = [.text("é"), .bytes(Data([1, 2, 3])), .null, .text("ab")]

        #expect(LibPQReadBound.byteCount(of: row) == 2 + 3 + 0 + 2)
    }
}
