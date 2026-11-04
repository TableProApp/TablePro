import SwiftUI
@testable import TableProMobile
import TableProModels
import Testing
import UIKit

// Each root is hosted with no ancestor, as macOS builds a presented root; an object it misses traps the host.
@MainActor
struct SceneObjectsTests {
    private let fixture: AppStateFixture
    private let objects: SceneObjects

    init() throws {
        fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        objects = SceneObjects(
            appState: appState,
            coordinatorStore: ConnectionCoordinatorStore(connectionManager: appState.connectionManager),
            presenter: ScenePresenter(),
            menuState: SceneMenuState()
        )
    }

    @Test("The connection cover renders with no environment from its presenter")
    func coverRendersOnItsOwn() throws {
        let absent = DatabaseConnection(name: "Absent", type: .sqlite, host: "", port: 0, database: "absent.sqlite")
        try expectRenders(ConnectionCover(connection: absent, objects: objects) {})
    }

    @Test("The connection form sheet renders with no environment from its presenter")
    func formSheetRendersOnItsOwn() throws {
        try expectRenders(ConnectionFormSheet(connection: nil, objects: objects) { _ in })
    }

    private func expectRenders(_ root: some View) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        #expect(host.view.window === window)
    }
}
