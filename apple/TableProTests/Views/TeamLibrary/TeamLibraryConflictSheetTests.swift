//
//  TeamLibraryConflictSheetTests.swift
//  TableProTests
//

import AppKit
import ApplicationServices
import SwiftUI
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryConflictSheetTests {
    private static func data(_ object: [String: Any]) throws -> TeamLibraryData {
        try JSONDecoder().decode(TeamLibraryData.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func conflict(op: Components.Schemas.LibraryEditOp = .upsert, mine: String = "select mine") throws -> TeamLibraryConflict {
        TeamLibraryConflict(
            teamID: "team_acme",
            edit: TeamLibraryEdit(
                baseVersion: 1,
                clientId: "q1",
                data: op == .delete ? nil : .init(additionalProperties: try data(["name": "Orders", "query": mine, "sort_order": 0])),
                kind: .query,
                op: op
            ),
            current: nil
        )
    }

    private static func current(deleted: Bool = false) throws -> TeamLibraryChange {
        TeamLibraryChange(
            clientId: "q1",
            data: deleted ? nil : .init(additionalProperties: try data(["name": "Orders", "query": "select theirs", "sort_order": 0])),
            deleted: deleted,
            kind: "query",
            updatedAt: Date(),
            version: 2
        )
    }

    @Test("A query conflict names the query and lays both SQL texts side by side")
    func queryConflictShowsBothCopies() throws {
        let presentation = TeamLibraryConflictPresentation(
            conflict: try Self.conflict(),
            current: try Self.current(),
            teamName: "Acme"
        )

        #expect(presentation.title.contains("Orders"))
        #expect(presentation.message.contains("Acme"))
        #expect(presentation.mine.lines.last == TeamLibraryVersionSummary.Line(label: "SQL", value: "select mine", isCode: true))
        #expect(presentation.theirs.lines.last == TeamLibraryVersionSummary.Line(label: "SQL", value: "select theirs", isCode: true))
        #expect(presentation.mine.removal == nil && presentation.theirs.removal == nil)
    }

    @Test("An item deleted on the team, or one this Mac removes, says so instead of showing fields")
    func removalsAreNamed() throws {
        let deletedThere = TeamLibraryConflictPresentation(
            conflict: try Self.conflict(),
            current: try Self.current(deleted: true),
            teamName: "Acme"
        )
        #expect(deletedThere.theirs.removal == String(localized: "Deleted from the team library"))
        #expect(deletedThere.theirs.lines.isEmpty)

        let removedHere = TeamLibraryConflictPresentation(
            conflict: try Self.conflict(op: .delete),
            current: try Self.current(),
            teamName: "Acme"
        )
        #expect(removedHere.mine.removal == String(localized: "Removed from the team library"))
        #expect(removedHere.title.contains("Orders"), "The name comes from the team's copy when this Mac sends none")

        let gone = TeamLibraryConflictPresentation(conflict: try Self.conflict(), current: nil, teamName: nil)
        #expect(gone.theirs.removal == String(localized: "No longer in the team library"))
    }

    @Test("Keep Mine and Keep Theirs are named buttons that VoiceOver can press")
    func buttonsPressThroughAccessibility() async throws {
        var kept: [Bool] = []
        var later = 0
        let view = TeamLibraryConflictContent(
            presentation: TeamLibraryConflictPresentation(
                conflict: try Self.conflict(),
                current: try Self.current(),
                teamName: "Acme"
            ),
            remaining: 2,
            isResolving: false,
            decideLater: { later += 1 },
            keep: { kept.append($0) }
        )
        let window = try await Self.host(view, showing: "team-library-conflict-keep-mine")
        defer { window.orderOut(nil) }

        let mine = try #require(Self.element("team-library-conflict-keep-mine", in: window))
        let theirs = try #require(Self.element("team-library-conflict-keep-theirs", in: window))
        let decideLater = try #require(Self.element("team-library-conflict-later", in: window))
        #expect(Self.label(of: mine) == String(localized: "Keep Mine"))
        #expect(Self.label(of: theirs) == String(localized: "Keep Theirs"))
        #expect(Self.element("team-library-conflict-mine", in: window) != nil)
        #expect(Self.element("team-library-conflict-theirs", in: window) != nil)

        Self.press(mine)
        try await waitUntil { kept == [true] }
        Self.press(theirs)
        try await waitUntil { kept == [true, false] }
        Self.press(decideLater)
        try await waitUntil { later == 1 }
    }

    @Test("The header shows a conflict count button, and a failed sync as a labeled symbol")
    func statusContent() async throws {
        var resolved = 0
        let window = try await Self.host(
            TeamLibrarySyncStatusContent(status: .failed(.offline), conflictCount: 2) { resolved += 1 }
                .frame(width: 240, height: 24),
            showing: "team-library-resolve-conflicts"
        )
        defer { window.orderOut(nil) }

        let button = try #require(Self.element("team-library-resolve-conflicts", in: window))
        #expect(Self.label(of: button) == TeamLibrarySyncDescription.conflicts(2))
        let failed = try #require(Self.element("team-library-status-failed", in: window))
        #expect(Self.label(of: failed)?.contains(String(localized: "TablePro couldn't reach the team library.")) == true)

        Self.press(button)
        try await waitUntil { resolved == 1 }
    }

    // MARK: - Helpers

    // Read through the AX API, as VoiceOver does: in process, a hosting view lists no SwiftUI children.
    private static func host(_ view: some View, showing identifier: String) async throws -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "TeamLibraryConflictSheetTests-\(UUID().uuidString)"
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        do {
            try await waitUntil { element(identifier, in: window) != nil }
        } catch {
            window.orderOut(nil)
            throw error
        }
        return window
    }

    private static func element(_ identifier: String, in window: NSWindow) -> AXUIElement? {
        let root = children(kAXWindowsAttribute, of: AXUIElementCreateApplication(getpid()))
            .first { string(kAXTitleAttribute, of: $0) == window.title }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 16 else { return nil }
            if string(kAXIdentifierAttribute, of: element) == identifier {
                return element
            }
            for child in children(kAXChildrenAttribute, of: element) {
                if let found = find(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return root.flatMap { find($0, depth: 0) }
    }

    private static func label(of element: AXUIElement) -> String? {
        let title = string(kAXTitleAttribute, of: element) ?? ""
        return title.isEmpty ? string(kAXDescriptionAttribute, of: element) : title
    }

    private static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func children(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
