//
//  MinimapHitTestTests.swift
//  TableProTests
//
//  Regression tests for #2156. Every TablePro editor is configured with `showMinimap: false`, which
//  hides the minimap but leaves it in the scroll view as a floating subview at its full width.
//  `MinimapView.hitTest` replaces `NSView`'s hit testing without repeating its hidden check, so the
//  hidden minimap answered for that width, and its empty `mouseDown` then discarded the click. The
//  trailing strip of the editor took clicks and did nothing with them.
//

import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing

@MainActor
@Suite("Hidden minimap hit testing")
struct MinimapHitTestTests {
    private static let paneWidth: CGFloat = 1_000
    private static let paneHeight: CGFloat = 300

    /// No window and no run loop turn. `MinimapView` overrides `visibleRect` to read its own inner
    /// scroll view's `documentVisibleRect`, which `layoutSubtreeIfNeeded` alone resolves, so the
    /// branch under test is reachable the same way `GutterHighlightTests` reaches its own.
    @MainActor
    private final class Harness {
        let host: NSView
        let controller: TextViewController

        init(showMinimap: Bool) {
            let theme = EditorTheme(
                text: EditorTheme.Attribute(color: .textColor),
                insertionPoint: .textColor,
                invisibles: EditorTheme.Attribute(color: .gray),
                background: .textBackgroundColor,
                lineHighlight: .selectedTextBackgroundColor,
                selection: .selectedTextColor,
                keywords: EditorTheme.Attribute(color: .systemPink),
                commands: EditorTheme.Attribute(color: .systemBlue),
                types: EditorTheme.Attribute(color: .systemMint),
                attributes: EditorTheme.Attribute(color: .systemTeal),
                variables: EditorTheme.Attribute(color: .systemCyan),
                values: EditorTheme.Attribute(color: .systemOrange),
                numbers: EditorTheme.Attribute(color: .systemYellow),
                strings: EditorTheme.Attribute(color: .systemRed),
                characters: EditorTheme.Attribute(color: .systemRed),
                comments: EditorTheme.Attribute(color: .systemGreen)
            )
            let configuration = SourceEditorConfiguration(
                appearance: .init(
                    theme: theme,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    lineHeightMultiple: 1.0,
                    wrapLines: false,
                    tabWidth: 4
                ),
                layout: .init(contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)),
                peripherals: .init(showGutter: true, showMinimap: showMinimap, showFoldingRibbon: false)
            )
            controller = TextViewController(
                string: "SELECT * FROM users;\nSELECT * FROM orders;",
                language: .default,
                configuration: configuration,
                cursorPositions: [],
                highlightProviders: []
            )

            let bounds = NSRect(x: 0, y: 0, width: paneWidth, height: paneHeight)
            host = NSView(frame: bounds)
            controller.loadView()
            controller.view.frame = bounds
            host.addSubview(controller.view)
            controller.viewWillAppear()
            controller.viewDidAppear()
            host.layoutSubtreeIfNeeded()
            controller.textView.layoutManager.layoutLines(in: bounds)
        }

        /// The centre of the minimap's strip, in `host` coordinates. Converted rather than
        /// computed: `host` is unflipped and the editor's views are flipped, so a hand-picked `y`
        /// means different places in the two spaces.
        var pointInMinimapStrip: NSPoint {
            let minimap: MinimapView = controller.minimapView
            return minimap.convert(NSPoint(x: minimap.bounds.midX, y: minimap.bounds.midY), to: host)
        }

        /// True when `MinimapView.hitTest`'s `visibleRect` branch, the one the fix short-circuits,
        /// would answer for the strip's centre. If this were ever false the two hidden-minimap tests
        /// would pass without the fix, so they assert it rather than trust it.
        var minimapStripIsLiveForHitTesting: Bool {
            let minimap: MinimapView = controller.minimapView
            return minimap.visibleRect.contains(NSPoint(x: minimap.bounds.midX, y: minimap.bounds.midY))
        }

        /// The trailing edge of the gutter, in `host` coordinates.
        var gutterMaxXInHost: CGFloat {
            let gutter: GutterView = controller.gutterView
            return gutter.convert(NSPoint(x: gutter.bounds.maxX, y: 0), to: host).x
        }

        func hit(_ point: NSPoint) -> NSView? {
            host.hitTest(point)
        }
    }

    @Test("A hidden minimap leaves the trailing strip to the text view")
    func hiddenMinimapDoesNotClaimItsStrip() throws {
        let harness = Harness(showMinimap: false)

        // Without these the test could pass because the strip is not there at all, or because the
        // branch the guard short-circuits never ran.
        #expect(harness.controller.minimapView.isHidden)
        #expect(harness.controller.minimapView.frame.width > 0)
        #expect(harness.minimapStripIsLiveForHitTesting)

        let hit = harness.hit(harness.pointInMinimapStrip)
        #expect(hit === harness.controller.textView)
    }

    @Test("The whole width right of the gutter answers for the text view when the minimap is off")
    func everyPointRightOfTheGutterReachesTheTextView() throws {
        let harness = Harness(showMinimap: false)
        #expect(harness.minimapStripIsLiveForHitTesting)
        let y = harness.pointInMinimapStrip.y

        var unreachable: [CGFloat] = []
        var x = harness.gutterMaxXInHost + 1
        while x < Self.paneWidth {
            if harness.hit(NSPoint(x: x, y: y)) !== harness.controller.textView {
                unreachable.append(x)
            }
            x += 1
        }
        #expect(unreachable.isEmpty, "x positions that do not reach the text view: \(unreachable)")
    }

    /// Also the guard on the two tests above. They only mean something in an environment where a
    /// minimap can claim a point at all, so if this fails they are passing for the wrong reason.
    @Test("A shown minimap still claims its strip")
    func shownMinimapStillClaimsItsStrip() throws {
        let harness = Harness(showMinimap: true)
        #expect(!harness.controller.minimapView.isHidden)

        let hit = try #require(harness.hit(harness.pointInMinimapStrip))
        #expect(
            hit === harness.controller.minimapView || hit.isDescendant(of: harness.controller.minimapView),
            "expected the minimap or one of its subviews, got \(type(of: hit))"
        )
    }
}
