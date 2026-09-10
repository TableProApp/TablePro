//
//  LineFoldHoverTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// The gutter's chevron and a collapsed fold's placeholder are two controls onto the same fold, so both report which
/// fold the pointer is on into one place. Splitting that state was what let the chevron stay dim while the reader was
/// pointing straight at the block it discloses.
@MainActor
struct LineFoldHoverTests {
    private let controller: TextViewController
    private let ribbon: LineFoldRibbonView
    private let model: LineFoldModel

    init() throws {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = "A\nB\nC\nD\nE\nF\n"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        ribbon = LineFoldRibbonView(controller: controller)
        ribbon.model?.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: [
                LineFoldStorage.RawFold(depth: 1, range: 1..<6),
                LineFoldStorage.RawFold(depth: 1, range: 7..<11)
            ]
        )
        model = try #require(ribbon.model)
    }

    private func fold(at index: Int) throws -> FoldRange {
        let folds = model.getFolds(in: 0..<controller.textView.textStorage.length)
        return try #require(folds.indices.contains(index) ? folds[index] : nil)
    }

    private func hover(for fold: FoldRange) -> LineFoldModel.PlaceholderHover {
        LineFoldModel.PlaceholderHover(
            fold: fold,
            hit: CollapsedFoldHit(hiddenRange: fold.range, blockRange: fold.range, rect: .zero)
        )
    }

    @Test("Pointing at a chevron marks its fold hovered")
    func gutterHoverMarksFold() throws {
        let first = try fold(at: 0)
        model.setGutterHover(first)

        #expect(model.hoveredFold?.id == first.id)
    }

    @Test("Pointing at a placeholder marks the same fold the chevron would")
    func placeholderHoverMarksFold() throws {
        let first = try fold(at: 0)
        model.setPlaceholderHover(hover(for: first))

        #expect(model.hoveredFold?.id == first.id)
    }

    @Test("A placeholder outranks the gutter, since it is over the text being pointed at")
    func placeholderWinsOverGutter() throws {
        let first = try fold(at: 0)
        let second = try fold(at: 1)
        model.setGutterHover(first)
        model.setPlaceholderHover(hover(for: second))

        #expect(model.hoveredFold?.id == second.id)
    }

    @Test("Leaving a placeholder falls back to whatever the gutter still reports")
    func leavingPlaceholderFallsBackToGutter() throws {
        let first = try fold(at: 0)
        let second = try fold(at: 1)
        model.setGutterHover(first)
        model.setPlaceholderHover(hover(for: second))
        model.setPlaceholderHover(nil)

        #expect(model.hoveredFold?.id == first.id)
    }

    @Test("Leaving both controls clears the hover")
    func leavingBothClearsHover() throws {
        let first = try fold(at: 0)
        model.setGutterHover(first)
        model.setGutterHover(nil)

        #expect(model.hoveredFold == nil)
    }

    @Test("A scroll that moves a placeholder is reported even though the fold did not change")
    func movedPlaceholderIsReported() throws {
        final class HoverSpy: TextViewCoordinator {
            var hits: [CollapsedFoldHit?] = []
            func prepareCoordinator(controller: TextViewController) {}
            func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?) {
                hits.append(hit)
            }
        }

        let spy = HoverSpy()
        controller.textCoordinators = [WeakCoordinator(spy)]

        let first = try fold(at: 0)
        var moved = hover(for: first)
        model.setPlaceholderHover(moved)
        moved = LineFoldModel.PlaceholderHover(
            fold: first,
            hit: CollapsedFoldHit(
                hiddenRange: first.range,
                blockRange: first.range,
                rect: CGRect(x: 0, y: 40, width: 30, height: 14)
            )
        )
        model.setPlaceholderHover(moved)

        #expect(spy.hits.count == 2, "A peek anchored to the old rect has to be told the anchor moved")
        #expect(spy.hits.last??.rect.origin.y == 40)
    }

    @Test("Reporting the same placeholder twice does not tell the app twice")
    func repeatedHoverIsNotReported() throws {
        final class HoverSpy: TextViewCoordinator {
            var hits: [CollapsedFoldHit?] = []
            func prepareCoordinator(controller: TextViewController) {}
            func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?) {
                hits.append(hit)
            }
        }

        let spy = HoverSpy()
        controller.textCoordinators = [WeakCoordinator(spy)]

        let first = try fold(at: 0)
        model.setPlaceholderHover(hover(for: first))
        model.setPlaceholderHover(hover(for: first))

        #expect(spy.hits.count == 1)
    }
}
