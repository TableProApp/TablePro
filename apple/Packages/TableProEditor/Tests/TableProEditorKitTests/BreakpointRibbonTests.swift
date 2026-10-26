//
//  BreakpointRibbonTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct BreakpointRibbonTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let controller: TextViewController
        private(set) var toggled: [Int] = []

        init(lineCount: Int = 20, windowHeight: CGFloat = 800, setUp: (TextViewController) -> Void = { _ in }) {
            let text = (1...lineCount).map { "SELECT \($0) FROM orders;" }.joined(separator: "\n")
            controller = TextViewController(
                string: text,
                language: .default,
                configuration: SourceEditorConfiguration(
                    appearance: .init(
                        theme: Mock.theme(),
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        wrapLines: false
                    ),
                    behavior: .init(isEditable: false),
                    peripherals: .init(showFoldingRibbon: false, showBreakpoints: true)
                ),
                cursorPositions: [],
                highlightProviders: []
            )
            setUp(controller)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: windowHeight),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            controller.view.layoutSubtreeIfNeeded()
            controller.textView.updateFrameIfNeeded()
            controller.textView.layoutManager.layoutLines()
            controller.gutterView.updateWidthIfNeeded()
            controller.viewDidAppear()

            controller.onBreakpointToggle = { [weak self] line in
                self?.toggled.append(line)
            }
        }

        var ribbon: BreakpointRibbonView {
            controller.gutterView.breakpointRibbon
        }

        func line(_ number: Int) throws -> TextLineStorage<TextLine>.TextLinePosition {
            try #require(controller.textView.layoutManager.textLineForIndex(number - 1))
        }

        func windowPoint(onLine number: Int) throws -> NSPoint {
            let line = try line(number)
            return ribbon.convert(NSPoint(x: ribbon.bounds.midX, y: line.yPos + line.height / 2), to: nil)
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        // Delivered to whatever the window hit-tests at the point, so a click that never reaches the ribbon fails.
        func click(downOnLine down: Int, upOnLine up: Int? = nil) throws {
            let downPoint = try windowPoint(onLine: down)
            let upPoint = try windowPoint(onLine: up ?? down)
            let target = try #require(window.contentView?.hitTest(downPoint))
            target.mouseDown(with: try mouse(.leftMouseDown, at: downPoint))
            target.mouseUp(with: try mouse(.leftMouseUp, at: upPoint))
        }

        func breakpointElements() -> [BreakpointElement] {
            (ribbon.accessibilityChildren() as? [BreakpointElement]) ?? []
        }

        func ribbonColor(onLine number: Int) throws -> NSColor? {
            let line = try line(number)
            let rect = NSRect(x: 0, y: line.yPos, width: ribbon.bounds.width, height: line.height)
            let rep = try #require(ribbon.bitmapImageRepForCachingDisplay(in: rect))
            ribbon.cacheDisplay(in: rect, to: rep)
            return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        }
    }

    private static func isRed(_ color: NSColor?) -> Bool {
        guard let color, color.alphaComponent > 0.5 else { return false }
        return color.redComponent > 0.7 && color.greenComponent < 0.5 && color.blueComponent < 0.5
    }

    private static func isGreen(_ color: NSColor?) -> Bool {
        guard let color, color.alphaComponent > 0.5 else { return false }
        return color.greenComponent > 0.6 && color.redComponent < 0.5 && color.blueComponent < 0.6
    }

    // MARK: - Clicks

    @Test("A click on a line without a breakpoint asks the host to add one there, in a read-only editor")
    func clickOnEmptyLineAsksToAdd() throws {
        let harness = Harness()
        try #require(!harness.controller.isEditable)
        #expect(harness.window.contentView?.hitTest(try harness.windowPoint(onLine: 3)) === harness.ribbon)

        try harness.click(downOnLine: 3)

        #expect(harness.toggled == [3])
        #expect(harness.controller.breakpointLines.isEmpty, "the editor leaves the set to the host")
    }

    @Test("A click on a breakpoint asks the host to remove it")
    func clickOnMarkerAsksToRemove() throws {
        let harness = Harness()
        harness.controller.breakpointLines = [7]

        try harness.click(downOnLine: 7)

        #expect(harness.toggled == [7])
        #expect(harness.controller.breakpointLines == [7])
    }

    @Test("Dragging off the line before releasing takes the click back")
    func dragOffCancels() throws {
        let harness = Harness()

        try harness.click(downOnLine: 3, upOnLine: 5)

        #expect(harness.toggled.isEmpty)
    }

    // MARK: - Drawing and accessibility

    @Test("Each breakpoint is drawn and published as one accessibility element")
    func eachBreakpointIsDrawnAndPublished() throws {
        let harness = Harness()
        harness.controller.breakpointLines = [2, 5]

        #expect(Self.isRed(try harness.ribbonColor(onLine: 2)))
        #expect(Self.isRed(try harness.ribbonColor(onLine: 5)))
        #expect(!Self.isRed(try harness.ribbonColor(onLine: 3)))

        let elements = harness.breakpointElements()
        #expect(elements.map { $0.line } == [2, 5])
        #expect(elements.map { $0.accessibilityLabel() } == ["Breakpoint, line 2", "Breakpoint, line 5"])
        #expect(elements.allSatisfy { $0.accessibilityRole() == .button })

        let line5 = try harness.line(5)
        let frame = try #require(elements.last?.accessibilityFrame())
        let expected = harness.window.convertToScreen(harness.ribbon.convert(
            NSRect(x: 0, y: line5.yPos, width: harness.ribbon.bounds.width, height: line5.height),
            to: nil
        ))
        #expect(frame == expected)
    }

    @Test("Pressing a breakpoint's element asks the host to remove it")
    func pressingElementAsksToRemove() throws {
        let harness = Harness()
        harness.controller.breakpointLines = [2, 5]

        let element = try #require(harness.breakpointElements().last)
        #expect(element.accessibilityPerformPress())

        #expect(harness.toggled == [5])
    }

    @Test("Removing a breakpoint drops its element")
    func removingBreakpointDropsElement() {
        let harness = Harness()
        harness.controller.breakpointLines = [2, 5]
        #expect(harness.breakpointElements().count == 2)

        harness.controller.breakpointLines = [5]

        #expect(harness.breakpointElements().map { $0.line } == [5])
    }

    @Test("The ribbon groups the breakpoints and announces no execution line while none is set")
    func ribbonGroup() {
        let harness = Harness()

        #expect(harness.ribbon.isAccessibilityElement())
        #expect(harness.ribbon.accessibilityRole() == .group)
        #expect(harness.ribbon.accessibilityLabel() == "Breakpoints")
        #expect(harness.ribbon.accessibilityValue() == nil)
    }

    // MARK: - Execution line

    @Test("Setting the execution line scrolls it into view, marks it and announces it")
    func executionLineScrollsAndIsExposed() throws {
        let harness = Harness(lineCount: 300, windowHeight: 300)
        let textView = try #require(harness.controller.textView)
        let start = try harness.line(250)
        #expect(start.yPos > textView.visibleRect.maxY, "starts out of view")

        harness.controller.executionLine = 250

        let line = try harness.line(250)
        #expect(textView.visibleRect.contains(CGPoint(x: textView.visibleRect.midX, y: line.yPos + line.height / 2)))
        #expect(harness.ribbon.accessibilityValue() as? String == "Paused at line 250")
        #expect(Self.isGreen(try harness.ribbonColor(onLine: 250)))
        #expect((textView as? SourceEditorTextView)?.executionLine == 250)

        harness.controller.executionLine = nil

        #expect(harness.ribbon.accessibilityValue() == nil)
        #expect(!Self.isGreen(try harness.ribbonColor(onLine: 250)))
    }

    @Test("The execution line is painted across the text, not on the lines beside it")
    func executionLineBand() throws {
        let harness = Harness(lineCount: 10)
        let textView = try #require(harness.controller.textView)

        func colorAtLineEnd(_ number: Int) throws -> NSColor? {
            let line = try harness.line(number)
            let rect = NSRect(x: textView.bounds.maxX - 20, y: line.yPos, width: 10, height: line.height)
            let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: rect))
            textView.cacheDisplay(in: rect, to: rep)
            return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        }

        let before = try #require(try colorAtLineEnd(4))
        harness.controller.executionLine = 4
        let marked = try #require(try colorAtLineEnd(4))
        let neighbour = try #require(try colorAtLineEnd(5))

        #expect(marked != before)
        #expect(marked.greenComponent > marked.redComponent && marked.greenComponent > marked.blueComponent)
        #expect(neighbour == before)
    }

    @Test("A line set before the editor appears is scrolled to once it does")
    func executionLineSetBeforeAppearing() throws {
        let harness = Harness(lineCount: 300, windowHeight: 300) { controller in
            controller.executionLine = 250
        }

        let line = try harness.line(250)
        let visible = harness.controller.textView.visibleRect
        #expect(visible.contains(CGPoint(x: visible.midX, y: line.yPos + line.height / 2)))
        #expect(!harness.controller.executionLineNeedsReveal)
    }

    @Test("A line set before the source arrives is scrolled to once the text replaces the document")
    func executionLineSetBeforeTheSourceArrives() throws {
        let harness = Harness(lineCount: 1, windowHeight: 300)
        let textView = try #require(harness.controller.textView)

        harness.controller.executionLine = 250
        #expect(harness.controller.executionLineNeedsReveal, "no line 250 to scroll to yet")
        let before = textView.visibleRect

        harness.controller.setText((1...300).map { "SELECT \($0) FROM orders;" }.joined(separator: "\n"))

        let line = try harness.line(250)
        let visible = textView.visibleRect
        #expect(visible.minY > before.minY)
        #expect(visible.contains(CGPoint(x: visible.midX, y: line.yPos + line.height / 2)))
        #expect(!harness.controller.executionLineNeedsReveal)
    }

    @Test("A breakpoint on the execution line keeps its own marker")
    func breakpointOnExecutionLine() throws {
        let harness = Harness()
        harness.controller.breakpointLines = [4]
        harness.controller.executionLine = 4

        let color = try harness.ribbonColor(onLine: 4)
        let edge = try harness.line(4)
        let rect = NSRect(x: 0, y: edge.yPos, width: harness.ribbon.bounds.width, height: edge.height)
        let rep = try #require(harness.ribbon.bitmapImageRepForCachingDisplay(in: rect))
        harness.ribbon.cacheDisplay(in: rect, to: rep)
        let reds = (0..<rep.pixelsWide).filter { x in
            Self.isRed(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }

        #expect(!reds.isEmpty, "the breakpoint is still drawn")
        #expect(!Self.isRed(color), "the execution arrow sits inside it")
        #expect(harness.breakpointElements().map { $0.line } == [4])
    }

    // MARK: - Width

    private func gutterWidth(_ peripherals: SourceEditorConfiguration.Peripherals) -> (TextViewController, CGFloat) {
        let controller = TextViewController(
            string: "SELECT 1;\nSELECT 2;",
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: Mock.theme(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false
                ),
                peripherals: peripherals
            ),
            cursorPositions: [],
            highlightProviders: []
        )
        controller.loadView()
        controller.gutterView.updateWidthIfNeeded()
        return (controller, controller.gutterView.frame.width)
    }

    @Test("A gutter without the breakpoint ribbon measures as one that never had it")
    func hiddenRibbonLeavesWidthUnchanged() {
        let (_, plain) = gutterWidth(.init(gutterFitsContent: true))
        let (controller, hidden) = gutterWidth(.init(gutterFitsContent: true, showBreakpoints: false))
        #expect(hidden == plain)
        #expect(controller.gutterView.breakpointRibbon.isHidden)
        #expect(controller.gutterView.breakpointRibbonWidth == 0)

        controller.configuration.peripherals.showBreakpoints = true
        let reserved = BreakpointRibbonView.width + controller.gutterView.breakpointRibbonPadding
        #expect(abs(controller.gutterView.frame.width - (plain + reserved)) < 0.001)
        #expect(controller.gutterView.breakpointRibbon.frame.width == BreakpointRibbonView.width)

        controller.configuration.peripherals.showBreakpoints = false
        #expect(controller.gutterView.frame.width == plain)
        #expect(controller.floatingSubviewInsets.left == plain)
    }

    @Test("Hidden breakpoints leave the run controls where they were")
    func hiddenRibbonLeavesRunControlsInPlace() {
        let (_, runOnly) = gutterWidth(.init(showStatementRunControls: true))
        let (controller, withHidden) = gutterWidth(.init(showStatementRunControls: true, showBreakpoints: false))
        #expect(withHidden == runOnly)
        #expect(controller.gutterView.statementRunRibbon.frame.minX == 0)

        controller.configuration.peripherals.showBreakpoints = true
        #expect(controller.gutterView.breakpointRibbon.frame.minX == 0)
        #expect(controller.gutterView.statementRunRibbon.frame.minX == controller.gutterView.breakpointRibbonWidth)
    }

    @Test("The ribbon fits in the margin a window-edge gutter already keeps")
    func ribbonFitsInWindowMargin() {
        let (_, plain) = gutterWidth(.init())
        let (_, shown) = gutterWidth(.init(showBreakpoints: true))
        #expect(shown == plain)
    }
}
