@testable import TablePro

/// Keeps every fixture a case built until the suite instance for that case goes away, so a helper
/// can hand back the bare coordinator and its teardown still runs before the next case.
@MainActor
final class CoordinatorFixtures {
    private var kept: [CoordinatorFixture] = []

    nonisolated init() {}

    func make(connection: DatabaseConnection = TestFixtures.makeConnection()) -> CoordinatorFixture {
        let fixture = CoordinatorFixture(connection: connection)
        kept.append(fixture)
        return fixture
    }
}
