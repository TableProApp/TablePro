//
//  DiffSurfaceThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct DiffSurfaceThemeTests {
    private static let width = 200

    /// One context line, then one added line, each as tall as the other.
    private static func unifiedDiff() -> some View {
        TextDiffView(
            pairs: [
                DiffPair(before: "select 1", after: "select 1", kind: .unchanged),
                DiffPair(before: nil, after: "select 2", kind: .added),
            ],
            beforeLabel: "Before",
            afterLabel: "After",
            layout: .unified
        )
        .frame(width: CGFloat(width))
    }

    private static func rowSamples(_ bitmap: NSBitmapImageRep) throws -> (context: NSColor, added: NSColor) {
        let x = bitmap.pixelsWide - 12
        let context = try ThemedRenderFixture.color(in: bitmap, x: x, y: bitmap.pixelsHigh / 4)
        let added = try ThemedRenderFixture.color(in: bitmap, x: x, y: bitmap.pixelsHigh * 3 / 4)
        return (context, added)
    }

    // MARK: - TextDiffView

    @Test("Under the default pair the text diff draws no fill of its own and the native grid tint")
    func textDiffDrawsNativelyUnderTheDefaultPair() throws {
        try ThemedRenderFixture.adopting(.builtIn) { _ in
            let bitmap = try ThemedRenderFixture.bitmap(of: Self.unifiedDiff())
            let samples = try Self.rowSamples(bitmap)
            let inserted = try ThemedRenderFixture.filled(NativeThemeColors.insertedRow)

            #expect(samples.context.alphaComponent < 0.01, "context line drew \(samples.context)")
            #expect(ThemedRenderFixture.matches(samples.added, inserted), "drew \(samples.added), native \(inserted)")
            #expect(ThemedRenderFixture.pixelCount(in: bitmap, where: ThemedRenderFixture.isMagenta) == 0)
        }
    }

    @Test("A theme's editor background, editor text and grid tint reach the text diff")
    func textDiffFollowsTheTheme() throws {
        let pair = try ThemedRenderFixture.pair([
            .editorBackground: "#102030",
            .editorText: "#FF00FF",
            .gridInserted: "#00FF00",
        ])
        try ThemedRenderFixture.adopting(pair) { _ in
            let bitmap = try ThemedRenderFixture.bitmap(of: Self.unifiedDiff())
            let samples = try Self.rowSamples(bitmap)
            let background = try ThemedRenderFixture.filled(HexColor.color("#102030"))
            let inserted = try ThemedRenderFixture.filled(HexColor.color("#00FF00"))

            #expect(ThemedRenderFixture.matches(samples.context, background), "drew \(samples.context)")
            #expect(ThemedRenderFixture.matches(samples.added, inserted), "drew \(samples.added)")
            #expect(ThemedRenderFixture.pixelCount(in: bitmap, where: ThemedRenderFixture.isMagenta) > 0)
        }
    }

    @Test("A changed pair maps onto the grid's insert, update and delete tints")
    func diffKindsMapOntoGridKinds() {
        #expect(TextDiffView.lineKind(.changed, side: .before) == .update)
        #expect(TextDiffView.lineKind(.changed, side: .after) == .update)
        #expect(TextDiffView.lineKind(.added, side: .after) == .insert)
        #expect(TextDiffView.lineKind(.removed, side: .before) == .delete)
        #expect(TextDiffView.lineKind(.unchanged, side: .before) == nil)
        #expect(TextDiffView.lineKind(.added, side: .before) == nil)
        #expect(TextDiffView.lineKind(.removed, side: .after) == nil)

        #expect(TextDiffView.lineKind(DiffUnifiedLine.Kind.added) == .insert)
        #expect(TextDiffView.lineKind(DiffUnifiedLine.Kind.removed) == .delete)
        #expect(TextDiffView.lineKind(DiffUnifiedLine.Kind.context) == nil)
    }

    // MARK: - File conflict sheet

    @Test("The file conflict diff keeps its own tints under the default pair")
    func fileConflictTintsAreNativeUnderTheDefaultPair() {
        ThemedRenderFixture.adopting(.builtIn) { engine in
            #expect(FileConflictRowHighlight.removed.tint(engine: engine, contrast: .standard) == .red.opacity(0.18))
            #expect(FileConflictRowHighlight.added.tint(engine: engine, contrast: .standard) == .green.opacity(0.18))
            #expect(FileConflictRowHighlight.filler.tint(engine: engine, contrast: .standard) == .gray.opacity(0.06))
            #expect(FileConflictRowHighlight.plain.tint(engine: engine, contrast: .standard) == .clear)
        }
    }

    @Test("The file conflict diff takes the grid's inserted and deleted tints from a theme")
    func fileConflictTintsFollowTheTheme() throws {
        let pair = try ThemedRenderFixture.pair([.gridInserted: "#00FF0040", .gridDeleted: "#FF000040"])
        ThemedRenderFixture.adopting(pair) { engine in
            #expect(
                FileConflictRowHighlight.removed.tint(engine: engine, contrast: .standard)
                    == Color(nsColor: engine.palette[.gridDeleted])
            )
            #expect(
                FileConflictRowHighlight.added.tint(engine: engine, contrast: .standard)
                    == Color(nsColor: engine.palette[.gridInserted])
            )
            #expect(FileConflictRowHighlight.filler.tint(engine: engine, contrast: .standard) == .gray.opacity(0.06))
            #expect(FileConflictRowHighlight.plain.tint(engine: engine, contrast: .standard) == .clear)
        }
        #expect(FileConflictRowHighlight.removed.lineKind == .delete)
        #expect(FileConflictRowHighlight.added.lineKind == .insert)
        #expect(FileConflictRowHighlight.filler.lineKind == nil)
    }

    // MARK: - AI walkthrough

    @Test("The walkthrough diff keeps its own tints as the native fallback")
    func walkthroughNativeTints() {
        #expect(AIChatWalkthroughBlockView.nativeTint(for: .insert) == .green.opacity(0.16))
        #expect(AIChatWalkthroughBlockView.nativeTint(for: .delete) == .red.opacity(0.16))
    }
}
