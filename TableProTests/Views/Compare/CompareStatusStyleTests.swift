//
//  CompareStatusStyleTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct CompareStatusStyleTests {
    @Test("Object and row statuses use the system green, orange and red under any theme")
    func statusTintsAreSystemColors() throws {
        try PaneThemeFixture.withEverySlotOverridden {
            #expect(CompareStatusStyle.tint(for: TableDiffStatus.onlyInSource) == .green)
            #expect(CompareStatusStyle.tint(for: TableDiffStatus.onlyInTarget) == .red)
            #expect(CompareStatusStyle.tint(for: TableDiffStatus.differs) == .orange)
            #expect(CompareStatusStyle.tint(for: TableDiffStatus.identical) == .secondary)

            #expect(CompareStatusStyle.tint(for: RowDiffKind.insert) == .green)
            #expect(CompareStatusStyle.tint(for: RowDiffKind.update) == .orange)
            #expect(CompareStatusStyle.tint(for: RowDiffKind.delete) == .red)
            #expect(CompareStatusStyle.tint(for: RowDiffKind.conflict) == .orange)
            #expect(CompareStatusStyle.tint(for: RowDiffKind.identical) == .secondary)

            #expect(CompareStatusStyle.success == .green)
            #expect(CompareStatusStyle.warning == .orange)
            #expect(CompareStatusStyle.error == .red)
        }
    }

    /// The text diff in Compare and in Version History paints its lines with these, so a theme that
    /// recolors the grid must not reach them.
    @Test("A row difference takes the default grid's tint, not the theme's")
    func rowTintsAreTheNativeGridTints() throws {
        try PaneThemeFixture.withEverySlotOverridden {
            #expect(ThemeEngine.shared.resolved.isOverridden(.gridInserted))
            #expect(CompareStatusStyle.rowTint(for: .insert) == Color(nsColor: NativeThemeColors.insertedRow))
            #expect(CompareStatusStyle.rowTint(for: .update) == Color(nsColor: NativeThemeColors.modifiedRow))
            #expect(CompareStatusStyle.rowTint(for: .delete) == Color(nsColor: NativeThemeColors.deletedRow))
            #expect(CompareStatusStyle.rowTint(for: .identical) == .clear)
            #expect(CompareStatusStyle.rowTint(for: .conflict) == .clear)
        }
    }

    @Test("The row tints stay faint system colors in both appearances")
    func rowTintsResolvePerAppearance() throws {
        let tints: [(NSColor, NSColor)] = [
            (NativeThemeColors.insertedRow, .systemGreen),
            (NativeThemeColors.modifiedRow, .systemYellow),
            (NativeThemeColors.deletedRow, .systemRed),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for (tint, base) in tints {
                    guard let resolved = tint.usingColorSpace(.sRGB), let system = base.usingColorSpace(.sRGB) else {
                        Issue.record("\(tint) has no sRGB form")
                        continue
                    }
                    #expect(resolved.alphaComponent < 0.5)
                    #expect(abs(resolved.redComponent - system.redComponent) < 0.01)
                    #expect(abs(resolved.greenComponent - system.greenComponent) < 0.01)
                    #expect(abs(resolved.blueComponent - system.blueComponent) < 0.01)
                }
            }
        }
    }
}
