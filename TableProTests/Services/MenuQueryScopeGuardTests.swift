//
//  MenuQueryScopeGuardTests.swift
//  TableProTests
//
//  AppKit auto-manages the window list at the foot of the Window menu, and titles each entry
//  "Title (Subtitle)" when the window carries a subtitle and exactly "Title" when it does not.
//  TablePro's windows carry no subtitle, so every open window contributes a menu-bar item whose
//  title is exactly its tab's title.
//
//  Several tab types resolve to a title that is also the name of a Database-menu command, because
//  the command and the tab are the same feature: Query Insights, Server Dashboard, Users & Roles,
//  ER Diagram, Create Table. That is correct in the product and cannot be renamed away. What it
//  means for a UI test is that `app.menuBars.menuItems["Query Insights"]` matches TWO elements once
//  that tab is open, and XCUITest fails the click with "Multiple matching elements found".
//
//  That shipped: QueryInsightsTabUITests resolved it unscoped and went red the moment the window
//  subtitle was removed. The fix is to scope the query to its own menu, and this guard is what
//  stops the next one being written unscoped.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Menu query scope guard")
struct MenuQueryScopeGuardTests {
    /// Every title a tab can give a window, and therefore every title AppKit can add to the Window
    /// menu. Taken from `WindowTitleResolver.resolveTitle`'s own switch rather than retyped, so a
    /// new tab type joins this list by construction.
    private static let windowTitles: [String] = [
        String(localized: "Server Dashboard"),
        String(localized: "Users & Roles"),
        String(localized: "Query Insights"),
        String(localized: "ER Diagram"),
        String(localized: "Create Table"),
        String(localized: "Source"),
        WindowTitleResolver.fallbackTitle,
    ]

    @Test("No UI test resolves a menu item by a title a window can also carry")
    func uiTestsScopeAmbiguousMenuQueries() throws {
        var offenders: [String] = []

        for url in try Self.uiTestSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
                guard line.contains("menuBars.menuItems[") else { continue }
                guard let title = Self.windowTitles.first(where: { line.contains("\"\($0)\"") }) else { continue }
                offenders.append("\(url.lastPathComponent):\(offset + 1) resolves \"\(title)\"")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A window showing this tab puts an item of the same title in the Window menu, so an \
            unscoped query matches two elements and the click fails. Scope it to its own menu, \
            e.g. app.menuBars.menuBarItems["Database"].menuItems[…]: \(offenders.sorted())
            """
        )
    }

    /// The resolver is the source of the list above. If it learns a title this suite does not know
    /// about, the guard silently stops covering it, so the two are compared here.
    @Test("The guarded titles still match what the resolver can return")
    func guardedTitlesMatchTheResolver() throws {
        let resolver = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("TablePro/Core/Services/Infrastructure/WindowTitleResolver.swift"),
            encoding: .utf8
        )
        let literals = Self.stringLiterals(in: resolver)
            .filter { !$0.isEmpty && $0 != "%@ Query" && !$0.contains("·") }

        let unguarded = literals.filter { !Self.windowTitles.contains($0) }
        #expect(
            unguarded.isEmpty,
            "WindowTitleResolver can return \(unguarded.sorted()), which this guard does not cover"
        )
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func stringLiterals(in source: String) -> [String] {
        var found: [String] = []
        for line in source.components(separatedBy: .newlines) {
            guard line.contains("String(localized:"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("///")
            else { continue }
            let parts = line.components(separatedBy: "\"")
            guard parts.count >= 2 else { continue }
            found.append(parts[1])
        }
        return found
    }

    private static func uiTestSources() throws -> [URL] {
        let root = try Self.repoRoot().appendingPathComponent("TableProUITests")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
