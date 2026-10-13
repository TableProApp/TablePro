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
    private static let changedKinds: [(RowDiffKind, ThemeSlot, NSColor)] = [
        (.insert, .gridInserted, NativeThemeColors.insertedRow),
        (.update, .gridModified, NativeThemeColors.modifiedRow),
        (.delete, .gridDeleted, NativeThemeColors.deletedRow),
    ]

    private static func hex(_ color: NSColor) -> String {
        HexColor.string(from: color)
    }

    @Test("Object and row statuses use the system green, orange and red under any theme")
    func statusTintsAreSystemColors() throws {
        try ThemeTestFixture.withEverySlotOverridden {
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

    @Test("Under the default pair a changed line draws the grid's native tint in both appearances")
    func rowTintsAreNativeUnderTheDefaultPair() throws {
        let palette = ThemePalette(revision: 920_001, source: ThemeSource())

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for (kind, _, native) in Self.changedKinds {
                let tint = try #require(CompareStatusStyle.rowTintColor(for: kind, palette: palette))
                appearance.performAsCurrentDrawingAppearance {
                    #expect(Self.hex(tint) == Self.hex(native), "\(kind) in \(name.rawValue)")
                }
            }
        }
        #expect(CompareStatusStyle.rowTintColor(for: .identical, palette: palette) == nil)
        #expect(CompareStatusStyle.rowTintColor(for: .conflict, palette: palette) == nil)
        #expect(CompareStatusStyle.rowTint(for: .identical, palette: palette) == .clear)
        #expect(CompareStatusStyle.rowTint(for: .conflict, palette: palette) == .clear)
    }

    @Test("A changed line takes the theme's grid tint in the appearance whose theme sets it")
    func rowTintsFollowTheThemeWhenOverridden() throws {
        let dark = try ThemeTestFixture.theme(.dark, [
            .gridInserted: "#00FF0040",
            .gridModified: "#FFFF0040",
            .gridDeleted: "#FF000040",
        ])
        let source = ThemeSource()
        source.update(ThemePair(light: BuiltInThemes.light, dark: dark))
        let palette = ThemePalette(revision: 920_002, source: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))

        for (kind, slot, native) in Self.changedKinds {
            let tint = try #require(CompareStatusStyle.rowTintColor(for: kind, palette: palette))
            darkAqua.performAsCurrentDrawingAppearance {
                #expect(Self.hex(tint) == dark.overrides[slot]?.hex, "\(kind) in Dark Aqua")
            }
            aqua.performAsCurrentDrawingAppearance {
                #expect(Self.hex(tint) == Self.hex(native), "\(kind) in Aqua")
            }
        }
    }

    @Test("The text diff reads the live theme through the shared engine")
    func rowTintsReadTheActiveTheme() throws {
        try ThemeTestFixture.withEverySlotOverridden {
            let palette = ThemeEngine.shared.palette
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                for (kind, _, _) in Self.changedKinds {
                    let tint = try #require(CompareStatusStyle.rowTintColor(for: kind, palette: palette))
                    appearance.performAsCurrentDrawingAppearance {
                        #expect(Self.hex(tint) == "#FF00FF", "\(kind) in \(name.rawValue)")
                    }
                }
            }
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

    // MARK: - Diffs with their own native tint

    @Test("A diff with its own tint keeps it under the default pair")
    func lineTintKeepsTheNativeUnderTheDefaultPair() {
        let native = Color.green.opacity(0.16)
        ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let engine = ThemeEngine.shared
            for kind in [RowDiffKind.insert, .update, .delete, .identical, .conflict] {
                #expect(CompareStatusStyle.lineTint(for: kind, native: native, engine: engine, contrast: .standard) == native)
            }
        }
    }

    @Test("A diff with its own tint takes the grid's tint where the theme sets one")
    func lineTintFollowsTheTheme() throws {
        let native = Color.red.opacity(0.16)
        let pair = try ThemeTestFixture.pair([.gridDeleted: "#FF000040"])
        ThemeTestFixture.adopting(pair, appearance: .dark) {
            let engine = ThemeEngine.shared
            let themed = Color(nsColor: engine.palette[.gridDeleted])
            #expect(CompareStatusStyle.lineTint(for: .delete, native: native, engine: engine, contrast: .standard) == themed)
            #expect(CompareStatusStyle.lineTint(for: .delete, native: native, engine: engine, contrast: .increased) == themed)
            #expect(CompareStatusStyle.lineTint(for: .insert, native: native, engine: engine, contrast: .standard) == native)
            #expect(CompareStatusStyle.lineTint(for: .identical, native: native, engine: engine, contrast: .standard) == native)
        }
    }

    // MARK: - Line text

    @Test("Diff text stays the system's own under the default pair")
    func lineTextIsNativeUnderTheDefaultPair() {
        ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let engine = ThemeEngine.shared
            for kind in [RowDiffKind?.none, .insert, .update, .delete] {
                #expect(CompareStatusStyle.lineTextOverride(for: kind, engine: engine, contrast: .standard) == nil)
            }
        }
    }

    @Test("A deleted line takes the grid's deleted text and every other line the editor's text")
    func lineTextFollowsTheTheme() throws {
        let pair = try ThemeTestFixture.pair([.editorText: "#E0E0E0", .gridDeletedText: "#FF555580"])
        ThemeTestFixture.adopting(pair, appearance: .dark) {
            let engine = ThemeEngine.shared
            let editorText = Color(nsColor: engine.palette[.editorText])
            let deletedText = Color(nsColor: engine.palette[.gridDeletedText])
            #expect(CompareStatusStyle.lineTextOverride(for: .delete, engine: engine, contrast: .standard) == deletedText)
            #expect(CompareStatusStyle.lineTextOverride(for: .insert, engine: engine, contrast: .standard) == editorText)
            #expect(CompareStatusStyle.lineTextOverride(for: nil, engine: engine, contrast: .standard) == editorText)
        }
    }

    @Test("A deleted line falls back to the editor's text when the theme leaves deleted text out")
    func deletedLineFallsBackToEditorText() throws {
        let pair = try ThemeTestFixture.pair([.editorText: "#E0E0E0"])
        ThemeTestFixture.adopting(pair, appearance: .dark) {
            let engine = ThemeEngine.shared
            let editorText = Color(nsColor: engine.palette[.editorText])
            #expect(CompareStatusStyle.lineTextOverride(for: .delete, engine: engine, contrast: .standard) == editorText)
        }

        let deletedOnly = try ThemeTestFixture.pair([.gridDeletedText: "#FF555580"])
        ThemeTestFixture.adopting(deletedOnly, appearance: .dark) {
            let engine = ThemeEngine.shared
            #expect(CompareStatusStyle.lineTextOverride(for: .insert, engine: engine, contrast: .standard) == nil)
            #expect(
                CompareStatusStyle.lineTextOverride(for: .delete, engine: engine, contrast: .standard)
                    == Color(nsColor: engine.palette[.gridDeletedText])
            )
        }
    }
}
