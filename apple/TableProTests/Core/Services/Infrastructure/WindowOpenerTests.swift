@testable import TablePro
import XCTest

@MainActor
final class WindowOpenerTests: XCTestCase {
    private var openedRequests: [ConnectionFormRequest] = []
    private var openedSettings: [SettingsRequest] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = WelcomeRouter.shared.consumePendingRequest()
        openedRequests = []
        openedSettings = []
        WindowOpener.shared.setWelcomePresenter {}
        WindowOpener.shared.setConnectionFormPresenter { [weak self] request, _ in
            self?.openedRequests.append(request)
        }
        WindowOpener.shared.setIntegrationsActivityPresenter {}
        WindowOpener.shared.setSettingsPresenter { [weak self] request in
            self?.openedSettings.append(request)
        }
    }

    override func tearDown() async throws {
        _ = WelcomeRouter.shared.consumePendingRequest()
        try await super.tearDown()
    }

    func testNewConnectionRoutesTheChooserInsteadOfOpeningAWindow() {
        WindowOpener.shared.openConnectionForm()

        guard case .chooseDatabaseType(let payload) = WelcomeRouter.shared.pendingRequest else {
            return XCTFail("New Connection must queue a chooser request even with no window open")
        }
        XCTAssertNil(payload.initialType)
        XCTAssertTrue(openedRequests.isEmpty)
    }

    func testPresentTypeChooserCarriesTheInitialType() {
        WindowOpener.shared.presentTypeChooser(initialType: .sqlite) { _ in }

        guard case .chooseDatabaseType(let payload) = WelcomeRouter.shared.pendingRequest else {
            return XCTFail("Expected a chooser request")
        }
        XCTAssertEqual(payload.initialType, .sqlite)
    }

    func testChoosingATypeStagesTheDraftWithoutOpeningTheWindow() {
        WindowOpener.shared.openConnectionForm()

        guard case .chooseDatabaseType(let payload) = WelcomeRouter.shared.pendingRequest else {
            return XCTFail("Expected a chooser request")
        }
        payload.onSelected(.mysql)

        XCTAssertTrue(openedRequests.isEmpty, "The window must not open while the chooser sheet is still up")

        WindowOpener.shared.openStagedConnectionForm()

        XCTAssertEqual(openedRequests.count, 1)
        guard let request = openedRequests.first, case .create(let draftId) = request else {
            return XCTFail("Expected a create request")
        }
        XCTAssertEqual(ConnectionFormDraftStore.shared.consume(draftId)?.type, .mysql)
    }

    func testEachStagedDraftOpensItsOwnWindow() {
        WindowOpener.shared.stageConnectionFormDraft(type: .mysql)
        WindowOpener.shared.openStagedConnectionForm()
        WindowOpener.shared.stageConnectionFormDraft(type: .postgresql)
        WindowOpener.shared.openStagedConnectionForm()

        XCTAssertEqual(openedRequests.count, 2)
        XCTAssertNotEqual(openedRequests.first, openedRequests.last)
    }

    func testTheStagedURLReachesTheWindowOpenedForIt() {
        guard case .success(let parsed) = ConnectionURLParser.parse("mysql://sam:secret@shop.example.com:3306/shop")
        else {
            return XCTFail("The fixture URL must parse")
        }

        WindowOpener.shared.stageConnectionFormDraft(parsedURL: parsed)
        WindowOpener.shared.openStagedConnectionForm()

        guard let request = openedRequests.first, case .create(let draftId) = request else {
            return XCTFail("Expected a create request")
        }
        let draft = ConnectionFormDraftStore.shared.consume(draftId)
        XCTAssertEqual(draft?.parsedURL?.host, "shop.example.com")
        XCTAssertEqual(draft?.parsedURL?.database, "shop")
    }

    func testOpeningWithNothingStagedDoesNothing() {
        WindowOpener.shared.openStagedConnectionForm()

        XCTAssertTrue(openedRequests.isEmpty)
    }

    func testAStagedDraftIsOpenedOnlyOnce() {
        WindowOpener.shared.stageConnectionFormDraft(type: .mysql)
        WindowOpener.shared.openStagedConnectionForm()
        WindowOpener.shared.openStagedConnectionForm()

        XCTAssertEqual(openedRequests.count, 1)
    }

    func testStagingASecondDraftDiscardsTheFirst() {
        WindowOpener.shared.stageConnectionFormDraft(type: .mysql)
        WindowOpener.shared.stageConnectionFormDraft(type: .postgresql)
        WindowOpener.shared.openStagedConnectionForm()

        XCTAssertEqual(openedRequests.count, 1)
        guard let request = openedRequests.first, case .create(let draftId) = request else {
            return XCTFail("Expected a create request")
        }
        XCTAssertEqual(ConnectionFormDraftStore.shared.consume(draftId)?.type, .postgresql)
    }

    func testEditingAConnectionRequestsThatConnectionsWindow() {
        let connectionId = UUID()

        WindowOpener.shared.openConnectionForm(editing: connectionId)

        XCTAssertEqual(openedRequests, [.edit(connectionId: connectionId)])
    }

    func testACallMadeBeforeItsPresenterIsRegisteredRunsOnceItArrives() {
        let opener = WindowOpener()
        var opened: [ConnectionFormRequest] = []
        let connectionId = UUID()

        opener.openConnectionForm(editing: connectionId)
        XCTAssertTrue(opened.isEmpty, "No presenter yet, so the call has to wait")

        opener.setConnectionFormPresenter { request, _ in opened.append(request) }

        XCTAssertEqual(opened, [.edit(connectionId: connectionId)])
    }

    // Lets the windows migrate to AppKit one at a time.
    func testRegisteringOneWindowDoesNotDiscardAnotherWindowsQueuedCall() {
        let opener = WindowOpener()
        var opened: [ConnectionFormRequest] = []
        let connectionId = UUID()

        opener.openConnectionForm(editing: connectionId)
        opener.setWelcomePresenter {}
        XCTAssertTrue(opened.isEmpty, "The connection form still has no presenter")

        opener.setConnectionFormPresenter { request, _ in opened.append(request) }

        XCTAssertEqual(opened, [.edit(connectionId: connectionId)])
    }

    func testTheRequestedSettingsPaneReachesThePresenter() {
        WindowOpener.shared.openSettings(tab: .plugins)

        XCTAssertEqual(openedSettings, [.open(.root(.plugins))])
    }

    func testOpeningSettingsWithoutAPaneAsksForNone() {
        WindowOpener.shared.openSettings()

        XCTAssertEqual(openedSettings, [.open(nil)])
    }

    // The pane used to travel through UserDefaults, so a queued call opened on whatever was stored.
    func testASettingsCallQueuedBeforeItsPresenterKeepsItsPane() {
        let opener = WindowOpener()
        var opened: [SettingsRequest] = []

        opener.openSettings(tab: .ai)
        XCTAssertTrue(opened.isEmpty, "No presenter yet, so the call has to wait")

        opener.setSettingsPresenter { opened.append($0) }

        XCTAssertEqual(opened, [.open(.root(.ai))])
    }

    func testASettingsLinkRoutesItsPaneToThePresenter() async {
        await LaunchIntentRouter.shared.route(.openSettings(.root(.mcp)))

        XCTAssertEqual(openedSettings, [.open(.root(.mcp))])
    }

    func testABareSettingsLinkAsksForNoPane() async {
        await LaunchIntentRouter.shared.route(.openSettings(nil))

        XCTAssertEqual(openedSettings, [.open(nil)])
    }

    func testEditingTheSameConnectionTwiceRequestsTheSameWindow() {
        let connectionId = UUID()

        WindowOpener.shared.openConnectionForm(editing: connectionId)
        WindowOpener.shared.openConnectionForm(editing: connectionId)

        XCTAssertEqual(openedRequests.count, 2)
        XCTAssertEqual(openedRequests.first, openedRequests.last)
    }
}
