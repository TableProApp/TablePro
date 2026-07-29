//
//  WindowOpenerTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class WindowOpenerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = WelcomeRouter.shared.consumePendingRequest()
    }

    override func tearDown() {
        _ = WelcomeRouter.shared.consumePendingRequest()
        super.tearDown()
    }

    func testNewConnectionRoutesTheChooserWithoutABridge() {
        WindowOpener.shared.openConnectionForm()

        guard case .chooseDatabaseType(let payload) = WelcomeRouter.shared.pendingRequest else {
            return XCTFail("New Connection must queue a chooser request even with no window open")
        }
        XCTAssertNil(payload.initialType)
    }

    func testPresentTypeChooserCarriesTheInitialType() {
        WindowOpener.shared.presentTypeChooser(initialType: .sqlite) { _ in }

        guard case .chooseDatabaseType(let payload) = WelcomeRouter.shared.pendingRequest else {
            return XCTFail("Expected a chooser request")
        }
        XCTAssertEqual(payload.initialType, .sqlite)
    }
}
