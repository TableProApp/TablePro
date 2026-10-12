//
//  StatusBarControlIconTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

/// File scope rather than a member: `@Test(arguments:)` reads its arguments from a nonisolated
/// context, which cannot touch a static on a `@MainActor` suite.
private let statusBarLabelStyles = [true, false]

/// A small bordered button takes its height from its glyph, so the status bar's controls stood at
/// three heights: measured, `eye` alone made an 18pt button, the circled filter 19pt and
/// `eye.slash` 20pt, and Columns grew a point the moment a column was hidden.
@MainActor
struct StatusBarControlIconTests {
    /// Every glyph the result status bar draws in a bordered control, in each of its states.
    private static let glyphs = [
        "eye",
        "eye.slash",
        "highlighter",
        "line.3.horizontal.decrease.circle",
        "line.3.horizontal.decrease.circle.fill",
    ]

    private func controlHeight(glyph: String, showsTitle: Bool) -> CGFloat {
        let control = Button {} label: {
            Label {
                Text(verbatim: "Filters")
            } icon: {
                Image(systemName: glyph)
                    .statusBarControlIcon(besideTitle: showsTitle)
            }
        }
        .controlSize(.small)

        let host = showsTitle
            ? NSHostingView(rootView: AnyView(control.labelStyle(.titleAndIcon)))
            : NSHostingView(rootView: AnyView(control.labelStyle(.iconOnly)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("Every glyph gives its control the same height", arguments: statusBarLabelStyles)
    func glyphDoesNotDecideTheControlHeight(showsTitle: Bool) {
        let heights = Self.glyphs.map { controlHeight(glyph: $0, showsTitle: showsTitle) }

        #expect(heights.allSatisfy { $0 > 0 }, "Expected every control to lay out, measured \(heights)")
        #expect(Set(heights).count == 1, "Measured \(heights) for \(Self.glyphs)")
    }
}
