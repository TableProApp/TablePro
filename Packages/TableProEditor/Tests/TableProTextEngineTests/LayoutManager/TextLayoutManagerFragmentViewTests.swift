import AppKit
@testable import TableProTextEngine
import Testing

@Suite
@MainActor
struct TextLayoutManagerFragmentViewTests {
    private static let viewportSize = CGSize(width: 800, height: 600)
    private static let statement = "SELECT col_a, col_b FROM some_table WHERE id = 12345 AND name = 'abc' OR "

    let scrollView: NSScrollView
    let textView: TextView
    let layoutManager: TextLayoutManager

    init() throws {
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: Self.viewportSize))
        textView = TextView(string: String(repeating: Self.statement, count: 700), wrapLines: true)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scrollView.documentView = textView
        textView.updateFrameIfNeeded()
        layoutManager = try #require(textView.layoutManager)
    }

    private func viewport(atY yPos: CGFloat) -> NSRect {
        NSRect(origin: CGPoint(x: 0, y: yPos), size: Self.viewportSize)
    }

    private func layoutBand(for viewport: NSRect, of manager: TextLayoutManager) -> Range<CGFloat> {
        let padding = manager.verticalLayoutPadding
        return max(viewport.minY - padding, 0)..<(viewport.maxY + padding)
    }

    private func lines(
        in band: Range<CGFloat>,
        of manager: TextLayoutManager
    ) -> [TextLineStorage<TextLine>.TextLinePosition] {
        manager
            .linesStartingAt(band.lowerBound, until: band.upperBound)
            .filter { !$0.range.isEmpty && $0.yPos < band.upperBound }
    }

    private func fragments(
        in band: Range<CGFloat>,
        of manager: TextLayoutManager
    ) -> [(fragment: LineFragment, yPos: CGFloat)] {
        lines(in: band, of: manager).flatMap { line in
            line.data.lineFragments.compactMap { fragmentPosition in
                let yPos = line.yPos + fragmentPosition.yPos
                guard yPos < band.upperBound, yPos + fragmentPosition.height > band.lowerBound else { return nil }
                return (fragmentPosition.data, yPos)
            }
        }
    }

    private func fragmentViews(of view: TextView) -> [LineFragmentView] {
        view.subviews.compactMap { $0 as? LineFragmentView }
    }

    private func expectViewsMatchBand(
        _ band: Range<CGFloat>,
        of manager: TextLayoutManager,
        in view: TextView,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = fragments(in: band, of: manager)
        let placedViews = fragmentViews(of: view).filter { !$0.isHidden }
        #expect(
            Set(manager.viewReuseQueue.usedViews.keys) == Set(expected.map(\.fragment.id)),
            "The placed views are not the fragments in the band",
            sourceLocation: sourceLocation
        )
        #expect(placedViews.count == expected.count, sourceLocation: sourceLocation)
        for (fragment, yPos) in expected {
            let view = placedViews.first { $0.lineFragment === fragment }
            #expect(
                view?.frame.minY == yPos,
                "No view at \(yPos) for a fragment in the band",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Counts the fragments the text view is showing right now that no visible view is drawing.
    private func blankFragments(in rect: NSRect, of manager: TextLayoutManager) -> Int {
        guard rect.height > 0 else { return 0 }
        var blanks = 0
        for linePosition in manager.linesStartingAt(rect.minY, until: rect.maxY) {
            guard linePosition.yPos < rect.maxY, !linePosition.range.isEmpty else { continue }
            for fragmentPosition in linePosition.data.lineFragments {
                let yPos = linePosition.yPos + fragmentPosition.yPos
                guard yPos < rect.maxY, yPos + fragmentPosition.height > rect.minY else { continue }
                let view = manager.viewReuseQueue.getView(forKey: fragmentPosition.data.id)
                if view == nil || view?.isHidden == true || view?.frame.minY != yPos {
                    blanks += 1
                }
            }
        }
        return blanks
    }

    /// A line hundreds of fragments long gets views for the fragments in the layout band and no others.
    @Test
    func longWrappedLineGetsViewsOnlyForTheLayoutBand() throws {
        let viewport = viewport(atY: 0)
        layoutManager.layoutLines(in: viewport)

        let line = try #require(layoutManager.lineStorage.first)
        #expect(line.data.lineFragments.count > 300)
        expectViewsMatchBand(layoutBand(for: viewport, of: layoutManager), of: layoutManager, in: textView)
        #expect(fragmentViews(of: textView).count < line.data.lineFragments.count / 3)
    }

    /// The line's recorded height and width cover every fragment, not only the ones that got a view. Reporting the
    /// band's height instead shrinks the document and leaves the line needing layout on every pass.
    @Test
    func firstLayoutInsideAWrappedLineRecordsTheWholeLine() throws {
        let viewport = viewport(atY: 3_000)
        layoutManager.layoutLines(in: viewport)

        let line = try #require(layoutManager.lineStorage.first)
        #expect(line.height == line.data.lineFragments.height)
        #expect(layoutManager.lineStorage.maxWidth == line.data.lineFragments.map(\.data.width).max())
        #expect(layoutManager.layoutLines(in: viewport).isEmpty, "The line was laid out again")
        expectViewsMatchBand(layoutBand(for: viewport, of: layoutManager), of: layoutManager, in: textView)
    }

    /// Scrolling inside one wrapped line places a view for every fragment that enters the band and releases the ones
    /// that leave, without typesetting the line again.
    @Test
    func scrollingInsideAWrappedLinePlacesEveryFragmentThatEntersTheBand() throws {
        layoutManager.layoutLines(in: viewport(atY: 0))
        let lineHeight = try #require(layoutManager.lineStorage.first).height
        let band = layoutBand(for: viewport(atY: lineHeight / 2), of: layoutManager)
        let bandFragmentCount = fragments(in: band, of: layoutManager).count
        let yPositions = Array(stride(from: 0, through: lineHeight - Self.viewportSize.height, by: 250))

        for yPos in yPositions + yPositions.reversed() {
            let viewport = viewport(atY: yPos)
            #expect(layoutManager.layoutLines(in: viewport).isEmpty, "Scrolling typeset the line again")
            expectViewsMatchBand(layoutBand(for: viewport, of: layoutManager), of: layoutManager, in: textView)
            #expect(fragmentViews(of: textView).count <= bandFragmentCount * 2)
        }
    }

    /// The same property as `scrollingInsideAWrappedLinePlacesEveryFragmentThatEntersTheBand`, driven the way AppKit
    /// drives it. Nothing here calls the layout manager: the clip view's bounds notification is what has to reach it,
    /// and it has to reach it before the scrolled content is drawn, or the band the scroll revealed renders empty.
    @Test
    func realScrollingLeavesNoFragmentInTheViewportWithoutAView() throws {
        textView.layout()
        let lineHeight = try #require(layoutManager.lineStorage.first).height
        var blanks = 0
        var maxAttachedViews = 0

        for yPos in stride(from: CGFloat(0), to: lineHeight - Self.viewportSize.height, by: 400) {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: yPos))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            blanks += blankFragments(in: textView.visibleRect, of: layoutManager)
            maxAttachedViews = max(maxAttachedViews, fragmentViews(of: textView).count)
        }

        #expect(blanks == 0, "Scrolling revealed fragments no view was drawing")
        let band = layoutBand(for: textView.visibleRect, of: layoutManager)
        #expect(maxAttachedViews <= fragments(in: band, of: layoutManager).count * 2)
    }

    /// Typing inside a wrapped line typesets it again, which replaces every fragment. Only the band's worth of them
    /// may end up with a view.
    @Test
    func editingInsideAWrappedLineKeepsItsViewsBoundedByTheBand() throws {
        let viewport = viewport(atY: 3_000)
        layoutManager.layoutLines(in: viewport)
        let bandFragmentCount = fragments(in: layoutBand(for: viewport, of: layoutManager), of: layoutManager).count
        let offset = try #require(layoutManager.textOffsetAtPoint(CGPoint(x: 40, y: 3_300)))

        for index in 0..<10 {
            textView.textStorage.replaceCharacters(in: NSRange(location: offset + index, length: 0), with: "x")
            layoutManager.layoutLines(in: viewport)

            expectViewsMatchBand(layoutBand(for: viewport, of: layoutManager), of: layoutManager, in: textView)
            #expect(fragmentViews(of: textView).count <= bandFragmentCount * 2)
        }
    }

    /// A document that does not wrap keeps one view per line in the band, and those views follow their lines when an
    /// edit above the viewport moves them.
    @Test
    func unwrappedDocumentGetsOneViewPerLineInTheBandAndFollowsEdits() throws {
        let strings = (0..<2_000).map { $0 % 10 == 9 ? "" : "SELECT * FROM table_\($0) WHERE id = \($0);" }
        let unwrapped = TextView(string: strings.joined(separator: "\n"))
        unwrapped.frame = NSRect(origin: .zero, size: Self.viewportSize)
        unwrapped.updateFrameIfNeeded()
        let manager = try #require(unwrapped.layoutManager)

        for yPos in [0, 9_000, 20_000, 4_000] as [CGFloat] {
            let viewport = viewport(atY: yPos)
            manager.layoutLines(in: viewport)
            let band = layoutBand(for: viewport, of: manager)
            expectViewsMatchBand(band, of: manager, in: unwrapped)
            #expect(Set(manager.viewReuseQueue.usedViews.keys).count == lines(in: band, of: manager).count)
        }

        unwrapped.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        let viewport = viewport(atY: 4_000)
        manager.layoutLines(in: viewport)
        expectViewsMatchBand(layoutBand(for: viewport, of: manager), of: manager, in: unwrapped)
    }
}
