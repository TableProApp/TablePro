//
//  ConnectionEditorWindowTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorWindowTests {
    private func postgres(name: String = "Orders") -> DatabaseConnection {
        DatabaseConnection(
            name: name,
            host: "db.example.com",
            port: 5_432,
            database: "orders",
            username: "app",
            type: .postgresql
        )
    }

    private func makeController(
        _ fixture: ConnectionEditorStoreFixture,
        _ request: ConnectionEditorStore.Request,
        facet: ConnectionEditorFacetChoice? = nil
    ) -> ConnectionEditorWindowController {
        ConnectionEditorWindowController(store: fixture.makeStore(request), facet: facet, frameAutosaveName: nil)
    }

    private func row(of facet: ConnectionFacet, in controller: ConnectionEditorWindowController) -> Int? {
        controller.sidebar.rows.firstIndex { $0.facet == facet }
    }

    // A SOCKS proxy with no host is an issue on SSH & Proxies, away from General.
    private func raiseProxyIssue(_ store: ConnectionEditorStore) throws -> FieldIssue {
        try #require(store.availableTransports.contains(.socksProxy))
        store.selectTransport(.socksProxy)
        return try #require(store.issues(for: .sshAndProxies).first { $0.blocksSave })
    }

    // MARK: - Sidebar

    @Test("The sidebar lists the layout's facets and nothing else")
    func sidebarListsLayoutFacets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let postgres = makeController(fixture, .new(type: .postgresql, parsedURL: nil))
        let sqlite = makeController(fixture, .new(type: .sqlite, parsedURL: nil))
        defer {
            postgres.close()
            sqlite.close()
        }

        for controller in [postgres, sqlite] {
            let layout = controller.store.layout
            let facets = controller.sidebar.rows.map { $0.facet }
            let titles = controller.sidebar.rows.map { $0.title }
            #expect(facets == layout.facetIDs)
            #expect(titles == layout.facets.map { $0.title })
            #expect(controller.sidebar.tableView.numberOfRows == layout.facets.count)
        }
        #expect(postgres.sidebar.rows.contains { $0.facet == .sslTLS })
        #expect(!sqlite.sidebar.rows.contains { $0.facet == .sslTLS })
    }

    @Test("The sidebar follows the store's selection, and a pick in the sidebar writes it back")
    func sidebarSelectionIsTwoWay() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let controller = makeController(fixture, .new(type: .postgresql, parsedURL: nil))
        defer { controller.close() }
        let appearance = try #require(row(of: .appearance, in: controller))
        let safeMode = try #require(row(of: .safeMode, in: controller))

        #expect(controller.sidebar.tableView.selectedRow == row(of: .general, in: controller))

        controller.store.selectedFacet = .appearance
        try await waitUntil { controller.sidebar.tableView.selectedRow == appearance }
        #expect(controller.detail.shownContent == .facet(.appearance))

        controller.sidebar.tableView.selectRowIndexes(IndexSet(integer: safeMode), byExtendingSelection: false)
        #expect(controller.store.selectedFacet == .safeMode)
        #expect(controller.detail.shownContent == .facet(.safeMode))
        #expect(controller.detail.visitedFacets == [.general, .appearance, .safeMode])
    }

    @Test("focus(on:) selects the issue's facet without giving the sidebar the keyboard")
    func focusSelectsTheIssueFacet() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let controller = makeController(fixture, .edit(connectionId: connection.id))
        defer { controller.close() }
        let issue = try raiseProxyIssue(controller.store)
        let proxies = try #require(row(of: .sshAndProxies, in: controller))

        controller.store.focus(on: issue)

        try await waitUntil { controller.sidebar.tableView.selectedRow == proxies }
        #expect(controller.detail.shownContent == .facet(.sshAndProxies))
        #expect(controller.window?.firstResponder !== controller.sidebar.tableView)
    }

    @Test("The issue mark shows while a facet has an error and goes when it is fixed")
    func issueMarkAppearsAndClears() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let controller = makeController(fixture, .edit(connectionId: connection.id))
        defer { controller.close() }
        #expect(!controller.sidebar.rows.contains { $0.hasIssues })

        let issue = try raiseProxyIssue(controller.store)
        try await waitUntil {
            controller.sidebar.rows.first { $0.facet == .sshAndProxies }?.hasIssues == true
        }
        let marked = try #require(controller.sidebar.cell(for: .sshAndProxies))
        #expect(!marked.issueMark.isHidden)
        #expect(marked.toolTip?.contains(issue.message) == true)
        #expect(marked.accessibilityLabel() == String(
            format: String(localized: "%1$@, %2$@"), ConnectionFacet.sshAndProxies.title, issue.message
        ))

        controller.store.update { $0.socksProxy.host = "proxy.example.com" }
        try await waitUntil {
            controller.sidebar.rows.first { $0.facet == .sshAndProxies }?.hasIssues == false
        }
        let cleared = try #require(controller.sidebar.cell(for: .sshAndProxies))
        #expect(cleared.issueMark.isHidden)
        #expect(cleared.toolTip == nil)
    }

    @Test("The issue mark turns white on the emphasized selection")
    func issueMarkFollowsEmphasis() throws {
        let cell = ConnectionEditorSidebarCell(identifier: NSUserInterfaceItemIdentifier("cell"))
        cell.backgroundStyle = .normal
        #expect(cell.issueMark.contentTintColor == .systemRed)
        cell.backgroundStyle = .emphasized
        #expect(cell.issueMark.contentTintColor == .alternateSelectedControlTextColor)
    }

    // MARK: - Opening on a facet

    @Test("A caller's facet opens the window there; one the type lacks leaves it on General")
    func opensOnTheNamedFacet() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let appearance = makeController(fixture, .new(type: .postgresql, parsedURL: nil), facet: .named(.appearance))
        let sqlite = makeController(fixture, .new(type: .sqlite, parsedURL: nil), facet: .named(.sslTLS))
        defer {
            appearance.close()
            sqlite.close()
        }

        #expect(appearance.store.selectedFacet == .appearance)
        #expect(appearance.detail.shownContent == .facet(.appearance))
        #expect(sqlite.store.selectedFacet == .general)
    }

    @Test("A recovery opens on the facet of the first issue that blocks Save")
    func recoveryOpensOnTheFirstIssue() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let controller = makeController(fixture, .edit(connectionId: connection.id))
        defer { controller.close() }
        let issue = try raiseProxyIssue(controller.store)
        controller.store.selectedFacet = .general

        controller.open(on: .firstIssue)

        #expect(controller.store.selectedFacet == .sshAndProxies)
        #expect(controller.store.focusRequest?.row == issue.row)
        #expect(controller.sidebar.tableView.selectedRow == row(of: .sshAndProxies, in: controller))
    }

    @Test("The opener hands the facet to the presenter, and a new connection asks for none")
    func openerCarriesTheFacet() {
        let opener = WindowOpener()
        var opened: [(ConnectionFormRequest, ConnectionEditorFacetChoice?)] = []
        opener.setConnectionFormPresenter { opened.append(($0, $1)) }
        let id = UUID()

        opener.openConnectionForm(editing: id, facet: .firstIssue)
        opener.stageConnectionFormDraft(type: .postgresql)
        opener.openStagedConnectionForm()

        #expect(opened.count == 2)
        #expect(opened.first?.0 == .edit(connectionId: id))
        #expect(opened.first?.1 == .firstIssue)
        #expect(opened.last?.1 == nil)
        if case .create(let draftId) = opened.last?.0 {
            _ = ConnectionFormDraftStore.shared.consume(draftId)
        }
    }

    // MARK: - Title

    @Test("The window is never blank-titled: the saved name stands in while Name is empty")
    func titleIsNeverBlank() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let fresh = makeController(fixture, .new(type: .postgresql, parsedURL: nil))
        let edited = makeController(fixture, .edit(connectionId: connection.id))
        defer {
            fresh.close()
            edited.close()
        }

        #expect(fresh.window?.title == String(localized: "New Connection"))
        #expect(fresh.window?.subtitle == fresh.store.traits.displayName)
        #expect(edited.window?.title == "Orders")
        #expect(edited.window?.isDocumentEdited == false)

        edited.store.update { $0.name = "" }
        try await waitUntil { edited.window?.isDocumentEdited == true }
        #expect(edited.window?.title == "Orders")

        edited.store.update { $0.name = "Billing" }
        try await waitUntil { edited.window?.title == "Billing" }
    }

    // MARK: - Record missing

    @Test("A connection deleted elsewhere shows the empty state with no facets to pick")
    func recordMissingShowsEmptyState() throws {
        let fixture = try ConnectionEditorStoreFixture()
        fixture.seed([postgres()])
        let controller = makeController(fixture, .edit(connectionId: UUID()))
        defer { controller.close() }

        #expect(controller.sidebar.rows.isEmpty)
        #expect(controller.sidebar.tableView.numberOfRows == 0)
        #expect(controller.detail.shownContent == .recordMissing)
        #expect(controller.window?.isDocumentEdited == false)
        #expect(controller.closeVerdict == .close)
    }

    // MARK: - Frame

    @Test("The width is fixed and the height defaults to 700, clamped to the screen")
    func defaultFrame() {
        let width = ConnectionEditorWindowFrame.contentWidth
        #expect(width == 780)
        #expect(ConnectionEditorWindowFrame.defaultContentSize(visibleHeight: 1_000) == NSSize(width: width, height: 700))
        #expect(ConnectionEditorWindowFrame.defaultContentSize(visibleHeight: 640) == NSSize(width: width, height: 560))
        #expect(ConnectionEditorWindowFrame.defaultContentSize(visibleHeight: 500) == NSSize(width: width, height: 480))
    }

    @Test("A restored frame keeps the fixed width and a height between 480 and the screen minus 80")
    func restoredFrameIsClamped() {
        let width = ConnectionEditorWindowFrame.contentWidth
        let clamp = ConnectionEditorWindowFrame.clampedContentSize
        #expect(clamp(NSSize(width: 560, height: 1_400), 900) == NSSize(width: width, height: 820))
        #expect(clamp(NSSize(width: 900, height: 300), 900) == NSSize(width: width, height: 480))
        #expect(clamp(NSSize(width: width, height: 640), 900) == NSSize(width: width, height: 640))
    }

    @Test("The window holds the editor's width and minimum height")
    func windowSizeLimits() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let controller = makeController(fixture, .new(type: .postgresql, parsedURL: nil))
        defer { controller.close() }
        let window = try #require(controller.window)
        let content = window.contentRect(forFrameRect: window.frame).size

        #expect(window.contentMinSize == NSSize(width: 780, height: 480))
        #expect(window.contentMaxSize.width == 780)
        #expect(abs(content.width - 780) < 1)
        #expect(content.height >= 480)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isRestorable)
    }

    // MARK: - Close guard

    @Test("Closing asks to save only when there is something Save could write")
    func closeVerdict() {
        #expect(ConnectionEditorCloseGuard.verdict(hasUnsavedChanges: false, isRecordMissing: false, connectionName: "Orders") == .close)
        #expect(ConnectionEditorCloseGuard.verdict(hasUnsavedChanges: true, isRecordMissing: true, connectionName: "Orders") == .close)
        let verdict = ConnectionEditorCloseGuard.verdict(hasUnsavedChanges: true, isRecordMissing: false, connectionName: "Orders")
        #expect(verdict == .askToSave(ConnectionEditorSavePrompt(connectionName: "Orders")))
        #expect(ConnectionEditorSavePrompt(connectionName: "Orders").title
            == String(format: String(localized: "Do you want to save the changes to “%@”?"), "Orders"))
    }

    @Test("The alert's buttons map to Save, Cancel and Don't Save in that order")
    func closeChoices() {
        let alert = ConnectionEditorCloseGuard.makeAlert(ConnectionEditorSavePrompt(connectionName: "Orders"))
        let titles = alert.buttons.map { $0.title }
        #expect(titles == [
            String(localized: "Save"), String(localized: "Cancel"), String(localized: "Don't Save"),
        ])
        #expect(ConnectionEditorCloseGuard.choice(for: .alertFirstButtonReturn) == .save)
        #expect(ConnectionEditorCloseGuard.choice(for: .alertSecondButtonReturn) == .cancel)
        #expect(ConnectionEditorCloseGuard.choice(for: .alertThirdButtonReturn) == .dontSave)
    }

    @Test("Cancel on an untouched editor closes it at once")
    func cancelWithoutEditsCloses() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let controller = makeController(fixture, .edit(connectionId: connection.id))

        #expect(controller.closeVerdict == .close)
        controller.requestClose()

        #expect(controller.store.isClosing)
    }

    @Test("Don't Save closes without writing; a Save that fails keeps the window; one that lands closes it")
    func closeChoicesAct() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])

        let discarding = makeController(fixture, .edit(connectionId: connection.id))
        discarding.store.update { $0.host = "replica.example.com" }
        #expect(discarding.closeVerdict == .askToSave(ConnectionEditorSavePrompt(connectionName: "Orders")))
        discarding.resolveClose(.dontSave)
        #expect(discarding.store.isClosing)
        #expect(fixture.storage.loadConnection(id: connection.id)?.host == "db.example.com")

        let blocked = makeController(fixture, .edit(connectionId: connection.id))
        defer { blocked.close() }
        blocked.store.update { $0.name = "" }
        blocked.store.selectedFacet = .appearance
        blocked.resolveClose(.save)
        #expect(!blocked.store.isClosing)
        #expect(blocked.store.selectedFacet == .general)

        let saving = makeController(fixture, .edit(connectionId: connection.id))
        saving.store.update { $0.host = "replica.example.com" }
        saving.resolveClose(.save)
        #expect(saving.store.isClosing)
        #expect(fixture.storage.loadConnection(id: connection.id)?.host == "replica.example.com")
    }

    @Test("An invalid field is not an alert: Save already shows it in place")
    func saveErrorAlerts() {
        let issue = FieldIssue(facet: .general, row: .builtIn(.name), message: "Name", severity: .error)
        #expect(!ConnectionEditorPresentations.alertsSaveError(nil))
        #expect(!ConnectionEditorPresentations.alertsSaveError(.invalid(issue)))
        #expect(ConnectionEditorPresentations.alertsSaveError(.keychainWriteFailed))
        #expect(ConnectionEditorPresentations.alertsSaveError(.recordMissing))
    }

    @Test("A test result keeps the server version only when it signed in")
    func testResultServerVersion() {
        #expect(ConnectionTestResult(succeeded: true, serverVersion: "16.4").serverVersion == "16.4")
        #expect(ConnectionTestResult(succeeded: false, serverVersion: "16.4").serverVersion == nil)
    }
}
