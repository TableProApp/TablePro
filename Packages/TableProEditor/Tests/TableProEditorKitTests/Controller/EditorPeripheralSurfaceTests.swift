//
//  EditorPeripheralSurfaceTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProGrammars
import TableProTextEngine
import Testing

@MainActor
@Suite("Editor peripheral surface")
struct EditorPeripheralSurfaceTests {
    private static let paneWidth: CGFloat = 1_000
    private static let paneHeight: CGFloat = 300

    @MainActor
    private final class Harness {
        let host: NSView
        let controller: TextViewController

        init(language: CodeLanguage = .default) {
            let configuration = SourceEditorConfiguration(
                appearance: .init(
                    theme: Mock.theme(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    lineHeightMultiple: 1.0,
                    wrapLines: false,
                    tabWidth: 4
                ),
                layout: .init(contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)),
                peripherals: .init(
                    showGutter: true,
                    showLineNumbers: true,
                    showFoldingRibbon: false,
                    showStatementRunControls: false,
                    gutterFitsContent: false,
                    showSpecialCharacters: true
                )
            )
            controller = TextViewController(
                string: "SELECT * FROM users;\nSELECT * FROM orders;",
                language: language,
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

        var gutterMaxXInHost: CGFloat {
            let gutter: GutterView = controller.gutterView
            return gutter.convert(NSPoint(x: gutter.bounds.maxX, y: 0), to: host).x
        }

        var textMidYInHost: CGFloat {
            controller.textView.convert(NSPoint(x: 0, y: controller.textView.bounds.midY), to: host).y
        }
    }

    @Test("Every point right of the gutter puts the caret in the text")
    func everyPointRightOfTheGutterReachesTheTextView() {
        let harness = Harness()
        let pointY = harness.textMidYInHost

        var unreachable: [CGFloat] = []
        var pointX = harness.gutterMaxXInHost + 1
        while pointX < Self.paneWidth {
            if harness.host.hitTest(NSPoint(x: pointX, y: pointY)) !== harness.controller.textView {
                unreachable.append(pointX)
            }
            pointX += 1
        }
        #expect(unreachable.isEmpty, "x positions that do not reach the text view: \(unreachable)")
    }

    @Test("Nothing floats over the trailing edge of the text")
    func nothingIsReservedOnTheTrailingEdge() {
        let harness = Harness()
        #expect(harness.controller.floatingSubviewInsets.right == 0)
        #expect(harness.controller.scrollView.floatingSubviewInsets.right == 0)
    }

    /// A driver names the language its query editor highlights, and four of them name JavaScript. A filter keyed on a
    /// language rather than on the editing the user is doing reaches an editable query that way, which is how tag
    /// completion came to run on every MQL keystroke after a `>`.
    @Test("The editor installs the same text filters whichever language a driver names")
    func filtersDoNotVaryByLanguage() {
        let sql = Harness().controller.textFilters.map { String(describing: type(of: $0)) }
        for language in CodeLanguage.allLanguages where language.id != .sql {
            let other = Harness(language: language).controller.textFilters.map { String(describing: type(of: $0)) }
            #expect(sql == other, "\(language.id) installs \(other) where SQL installs \(sql)")
        }
    }
}
