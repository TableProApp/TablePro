//
//  WelcomeRouterTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class WelcomeRouterTests: XCTestCase {
    private var router: WelcomeRouter!

    override func setUp() {
        super.setUp()
        router = WelcomeRouter()
    }

    override func tearDown() {
        router = nil
        super.tearDown()
    }

    private func makeChooserPayload(
        initialType: DatabaseType? = nil,
        onSelected: @escaping (DatabaseType) -> Void = { _ in }
    ) -> DatabaseTypeChooserPayload {
        DatabaseTypeChooserPayload(initialType: initialType, onSelected: onSelected)
    }

    func testRouteStoresRequestWithoutASubscriber() {
        router.route(.exportConnections)

        guard case .exportConnections = router.pendingRequest else {
            return XCTFail("Expected the request to survive without a mounted Welcome window")
        }
    }

    func testConsumeReturnsRequestOnceThenNil() {
        router.route(.importFromApp)

        guard case .importFromApp = router.consumePendingRequest() else {
            return XCTFail("Expected the routed request")
        }
        XCTAssertNil(router.consumePendingRequest())
        XCTAssertNil(router.pendingRequest)
    }

    func testSecondRouteReplacesAnUnconsumedRequest() {
        router.route(.exportConnections)
        router.route(.openProjectFolder)

        guard case .openProjectFolder = router.consumePendingRequest() else {
            return XCTFail("Expected the most recent request to win")
        }
        XCTAssertNil(router.consumePendingRequest())
    }

    func testChooserRequestCarriesItsPayload() {
        var selected: DatabaseType?
        let payload = makeChooserPayload(initialType: .postgresql) { selected = $0 }

        router.route(.chooseDatabaseType(payload))

        guard case .chooseDatabaseType(let delivered) = router.consumePendingRequest() else {
            return XCTFail("Expected a chooser request")
        }
        XCTAssertEqual(delivered.initialType, .postgresql)
        delivered.onSelected(.mysql)
        XCTAssertEqual(selected, .mysql)
    }

    func testRequestSlotIsIndependentOfTheOtherPendingSlots() {
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        router.routePluginInstall(connection)
        router.route(.importConnections)

        guard case .importConnections = router.consumePendingRequest() else {
            return XCTFail("Expected the request slot to be untouched by routePluginInstall")
        }
        XCTAssertEqual(router.consumePendingPluginInstall()?.id, connection.id)
    }
}
