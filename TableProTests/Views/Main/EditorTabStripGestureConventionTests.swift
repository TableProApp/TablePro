//
//  EditorTabStripGestureConventionTests.swift
//  TableProTests
//
//  The tab strip promotes a preview tab on a double-click by reading the click count off the event
//  AppKit is dispatching, never by composing a SwiftUI tap gesture. That is not a style preference,
//  it is the only shape that measured acceptable. Driven with CGEvents posted to .cghidEventTap so
//  the window server assigned the click count itself, against a Button carrying the strip's own
//  shape, with NSEvent.doubleClickInterval at its 0.5s default:
//
//      Button alone (the shipping strip)              single: select +33ms   double: select, select
//      + .onTapGesture(count: 2)                      single: select +371ms  double: PROMOTE only
//      + .simultaneousGesture(TapGesture(count: 2))   single: select +26ms   double: select, PROMOTE, select
//      + reading NSApp.currentEvent.clickCount        single: select +22ms   double: select, select, PROMOTE
//
//  So a count:2 tap gesture holds every selection back 371ms and drops it entirely on the double,
//  and a simultaneous one selects twice. Neither is visible to any other test: the tab still
//  selects and still promotes, just late, or twice. Hence this guard.
//

import Foundation
import Testing

@Suite("Editor tab strip gesture convention")
struct EditorTabStripGestureConventionTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// One spelling covers both, because `onTapGesture(count:` contains `TapGesture(count:`.
    /// Listing them separately made a single offence report twice.
    private static let bannedGestures = ["TapGesture(count:"]

    /// Comments are dropped before the scan, because the file documents the measurement above by
    /// naming the very spellings this test bans.
    private func code(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("The tab strip composes no multi-click SwiftUI tap gesture")
    func stripUsesNoMultiClickTapGesture() throws {
        let url = Self.repositoryRoot.appendingPathComponent("TablePro/Views/Main/EditorTabStrip.swift")
        let source = code(of: try String(contentsOf: url, encoding: .utf8))

        let offenders = Self.bannedGestures.filter { source.contains($0) }

        #expect(
            offenders.isEmpty,
            """
            EditorTabStrip.swift uses \(offenders.joined(separator: ", ")). A multi-click SwiftUI \
            tap gesture delays every tab selection by ~371ms and suppresses it on the double-click. \
            Resolve the click through EditorTabActivationResolver instead.
            """
        )
    }

    /// A scan that stops matching anything is a test that passes forever. This pins both halves:
    /// a real call is still caught, and the comment that documents it is still ignored.
    @Test("The scan catches a real gesture and ignores one named in a comment")
    func scanCatchesCodeButNotComments() {
        let withCall = code(of: "    .onTapGesture(count: 2) { keep() }")
        #expect(Self.bannedGestures.contains { withCall.contains($0) })

        let withComment = code(of: "    /// Never .onTapGesture(count: 2), it costs 371ms.")
        #expect(Self.bannedGestures.contains { withComment.contains($0) } == false)
    }
}
