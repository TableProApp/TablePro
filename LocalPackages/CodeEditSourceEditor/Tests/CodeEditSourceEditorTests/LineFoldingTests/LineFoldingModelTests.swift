//
//  LineFoldingModelTests.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/8/25.
//

import Testing
import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor

@MainActor
struct LineFoldingModelTests {
    /// Makes a fold pattern that increases until halfway through the document then goes back to zero.
    @MainActor
    class HillPatternFoldProvider: LineFoldProvider {
        func foldLevelAtLine(
            lineNumber: Int,
            lineRange: NSRange,
            previousDepth: Int,
            controller: TextViewController
        ) -> [LineFoldProviderLineInfo] {
            let halfLineCount = (controller.textView.layoutManager.lineCount / 2) - 1

            return if lineNumber > halfLineCount {
                [
                    .startFold(
                        rangeStart: lineRange.location,
                        newDepth: controller.textView.layoutManager.lineCount - 2 - lineNumber
                    )
                ]
            } else {
                [
                    .endFold(rangeEnd: lineRange.location, newDepth: lineNumber)
                ]
            }
        }
    }

    let controller: TextViewController
    let textView: TextView

    init() {
        controller = Mock.textViewController(theme: Mock.theme())
        textView = controller.textView
        textView.string = "A\nB\nC\nD\nE\nF\n"
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    /// A little unintuitive but we only expect two folds with this. Our provider goes 0-1-2-2-1-0, but we don't
    /// make folds for indent level 0. We also expect folds to start on the lines *before* the indent increases and
    /// after it decreases, so the fold covers the start/end of the region being folded.
    @Test
    func buildFoldsForDocument() async throws {
        let provider = HillPatternFoldProvider()
        controller.foldProvider = provider
        let model = LineFoldModel(controller: controller, foldView: NSView())

        var cacheUpdated = model.$foldCache.values.makeAsyncIterator()
        _ = await cacheUpdated.next()
        _ = await cacheUpdated.next()

        let fold = try #require(model.getFolds(in: 0..<6).first)
        #expect(fold.range == 2..<10)
        #expect(fold.depth == 1)
        #expect(fold.isCollapsed == false)
    }
}
