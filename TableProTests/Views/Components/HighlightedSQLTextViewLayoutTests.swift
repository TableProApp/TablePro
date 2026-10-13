//
//  HighlightedSQLTextViewLayoutTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct HighlightedSQLTextViewLayoutTests {
    private static let longClause = (1 ... 4)
        .map { "customer_name_\($0) LIKE '%some fairly long fragment \($0)%'" }
        .joined(separator: " AND ")

    private static let longStatement = #"VACUUM (FULL, FREEZE, VERBOSE, ANALYZE) "public"."orders_with_a_very_long_table_name_for_testing""#

    private static let maintenanceSize = NSSize(width: 420, height: 520)

    private var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: ThemeEngine.shared.editorFonts.font)
    }

    private func maintenanceSheet(_ statements: [String], databaseType: DatabaseType = .postgresql) -> MaintenanceSheet {
        MaintenanceSheet(
            operation: PluginMaintenanceOperation(name: "VACUUM", appliesTo: [.table], scope: .object),
            tableName: "orders",
            databaseName: "app",
            databaseType: databaseType,
            preview: { _ in statements },
            onExecute: { _ in }
        )
    }

    /// TextKit 2 lays out lazily, so the whole document is laid out before its size is read.
    private func usedSize(of textView: NSTextView) -> NSSize {
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            return layoutManager.usageBoundsForTextContainer.size
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).size
    }

    private func textWidth(in scrollView: NSScrollView, textView: NSTextView) -> CGFloat {
        scrollView.contentSize.width - textView.textContainerInset.width * 2
    }

    // MARK: - Filter preview

    @Test("A long filter clause wraps inside the preview instead of running past its edge")
    func filterPreviewWraps() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(SQLPreviewSheet(sql: Self.longClause), size: NSSize(width: 480, height: 300))
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            let scrollView = try #require(textView.enclosingScrollView)

            #expect(textView.textContainer?.widthTracksTextView == true)
            #expect(!textView.isHorizontallyResizable)
            #expect(!scrollView.hasHorizontalScroller)
            #expect(textView.frame.width <= scrollView.contentSize.width + 0.5)

            let used = usedSize(of: textView)
            #expect(used.width <= textWidth(in: scrollView, textView: textView) + 0.5)
            #expect(used.height > lineHeight * 2)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Maintenance preview

    @Test("A long maintenance statement wraps and the preview grows to show all of it")
    func maintenancePreviewFitsWrappedStatement() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(maintenanceSheet([Self.longStatement]), size: Self.maintenanceSize)
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            let scrollView = try #require(textView.enclosingScrollView)
            let insets = textView.textContainerInset.height * 2

            #expect(textView.textContainer?.widthTracksTextView == true)
            #expect(!scrollView.hasHorizontalScroller)
            #expect(scrollView.frame.height > lineHeight * 2 + insets)
            #expect(scrollView.frame.height < lineHeight * CGFloat(MaintenanceSheet.previewMaxLines) + insets)

            let used = usedSize(of: textView)
            #expect(used.width <= textWidth(in: scrollView, textView: textView) + 0.5)
            #expect(used.height + insets <= scrollView.contentSize.height + 0.5)
            withExtendedLifetime(window) {}
        }
    }

    @Test("A preview taller than its cap stops at the cap and scrolls vertically")
    func maintenancePreviewCapsAndScrolls() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let statements = Array(repeating: Self.longStatement, count: 6)
            let window = ThemeTestFixture.host(maintenanceSheet(statements), size: Self.maintenanceSize)
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            let scrollView = try #require(textView.enclosingScrollView)
            let insets = textView.textContainerInset.height * 2
            let cap = lineHeight * CGFloat(MaintenanceSheet.previewMaxLines) + insets

            #expect(abs(scrollView.frame.height - cap) < 1)
            #expect(scrollView.hasVerticalScroller)

            let used = usedSize(of: textView)
            #expect(used.width <= textWidth(in: scrollView, textView: textView) + 0.5)
            #expect(used.height + insets > scrollView.contentSize.height)
            withExtendedLifetime(window) {}
        }
    }

    @Test("The maintenance preview highlights in the connection's query language")
    func maintenancePreviewUsesConnectionLanguage() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(
                maintenanceSheet(["db.orders.reIndex()"], databaseType: .mongodb),
                size: Self.maintenanceSize
            )
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            let color = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let palette = ThemeEngine.shared.palette

            #expect(ThemeTestFixture.hex(color) == ThemeTestFixture.hex(palette[.syntaxKeyword]))
            #expect(ThemeTestFixture.hex(color) != ThemeTestFixture.hex(palette[.editorText]))
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Other callers

    @Test("Without a line layout, long lines stay unwrapped and the view fills the space it is given")
    func defaultLayoutUnchanged() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let size = NSSize(width: 300, height: 200)
            let window = ThemeTestFixture.host(HighlightedSQLTextView(sql: Self.longClause), size: size)
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            let scrollView = try #require(textView.enclosingScrollView)

            #expect(textView.textContainer?.widthTracksTextView == false)
            #expect(textView.isHorizontallyResizable)
            #expect(!scrollView.autohidesScrollers)
            #expect(scrollView.frame.size == size)
            #expect(usedSize(of: textView).height < lineHeight * 1.5)
            withExtendedLifetime(window) {}
        }
    }
}
