//
//  LineFoldStorageTests.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/29/25.
//

import Testing
@testable import CodeEditSourceEditor

struct LineFoldStorageTests {
    // Helper to create a collapsed provider set
    private func collapsedSet(_ items: (Int, Int)...) -> Set<LineFoldStorage.DepthStartPair> {
        Set(items.map { (depth, start) in
            LineFoldStorage.DepthStartPair(depth: depth, start: start)
        })
    }

    @Test
    func emptyStorage() {
        let storage = LineFoldStorage(documentLength: 50)
        let folds = storage.folds(in: 0..<50)
        #expect(folds.isEmpty)
    }

    @Test
    func updateFoldsBasic() {
        var storage = LineFoldStorage(documentLength: 20)
        let raw: [LineFoldStorage.RawFold] = [
            LineFoldStorage.RawFold(depth: 1, range: 0..<5),
            LineFoldStorage.RawFold(depth: 2, range: 5..<10)
        ]
        storage.updateFolds(from: raw, collapsedRanges: [])

        let folds = storage.folds(in: 0..<20)
        #expect(folds.count == 2)
        #expect(folds[0].depth == 1 && folds[0].range == 0..<5 && folds[0].isCollapsed == false)
        #expect(folds[1].depth == 2 && folds[1].range == 5..<10 && folds[1].isCollapsed == false)
    }

    @Test
    func preserveCollapseState() {
        var storage = LineFoldStorage(documentLength: 15)
        let raw = [LineFoldStorage.RawFold(depth: 1, range: 0..<5)]
        // First pass: no collapsed
        storage.updateFolds(from: raw, collapsedRanges: [])
        #expect(storage.folds(in: 0..<15).first?.isCollapsed == false)

        // Second pass: provider marks depth=1, start=0 as collapsed
        storage.updateFolds(from: raw, collapsedRanges: collapsedSet((1, 0)))
        #expect(storage.folds(in: 0..<15).first?.isCollapsed == true)
    }
}
