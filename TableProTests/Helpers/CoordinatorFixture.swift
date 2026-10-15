@testable import TablePro

/// Tears the coordinator down when the fixture goes away: an untorn coordinator keeps its
/// termination observer and schema load task alive into later cases.
@MainActor
final class CoordinatorFixture {
    let connection: DatabaseConnection
    let tabManager = QueryTabManager()
    let changeManager = DataChangeManager()
    let coordinator: MainContentCoordinator
    private let injectedSession: Bool

    init(
        connection: DatabaseConnection = TestFixtures.makeConnection(),
        driver: (any DatabaseDriver)? = nil,
        services: AppServices = .live
    ) {
        self.connection = connection
        if let driver {
            var session = ConnectionSession(connection: connection, driver: driver)
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)
        }
        injectedSession = driver != nil
        coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: ConnectionToolbarState(),
            services: services
        )
    }

    @discardableResult
    func addTab(_ tab: QueryTab, rows: TableRows? = nil, select: Bool = true) -> QueryTab {
        tabManager.tabs.append(tab)
        if select { tabManager.selectedTabId = tab.id }
        if let rows { coordinator.setActiveTableRows(rows, for: tab.id) }
        return tab
    }

    isolated deinit {
        if !coordinator.isTearingDown { coordinator.teardown() }
        if injectedSession { DatabaseManager.shared.removeSession(for: connection.id) }
    }
}
