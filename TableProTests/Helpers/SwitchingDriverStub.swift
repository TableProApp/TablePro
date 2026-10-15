import Foundation
import TableProPluginKit

/// A driver whose database switch lands, so a case sees the session browse the database it asked
/// for. `MockDatabaseDriver` is not a plugin adapter, and its switch never moves the session.
final class SwitchingDriverStub: PluginDriverStub, @unchecked Sendable {
    private(set) var currentDatabase: String?

    func switchDatabase(to database: String) async throws {
        currentDatabase = database
    }
}
