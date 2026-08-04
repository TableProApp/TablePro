//
//  WindowOpenerTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class WindowOpenerTests: XCTestCase {
    private var openedRequests: [ConnectionFormRequest] = []

    override func setUp() {
        super.setUp()
        _ = WelcomeRouter.shared.consumePendingRequest()
        openedRequests = []
        WindowOpener.shared.wire(
            openWelcome: {},
            openConnectionForm: { [weak self] request in
                self?.openedRequests.append(request)
            },
            openIntegrationsActivity: {},
            openSettings: {}
        )
    }

    override func tearDown() {
        _ = WelcomeRouter.shared.consumePendingRequest()
        super.tearDown()
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

    func testEditingTheSameConnectionTwiceRequestsTheSameWindow() {
        let connectionId = UUID()

        WindowOpener.shared.openConnectionForm(editing: connectionId)
        WindowOpener.shared.openConnectionForm(editing: connectionId)

        XCTAssertEqual(openedRequests.count, 2)
        XCTAssertEqual(openedRequests.first, openedRequests.last)
    }
}
