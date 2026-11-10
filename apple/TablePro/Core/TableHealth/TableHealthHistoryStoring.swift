import Foundation

extension Notification.Name {
    static let tableHealthHistoryDidChange = Notification.Name("com.TablePro.tableHealthHistoryDidChange")
}

enum TableHealthHistoryChange {
    static let connectionIdKey = "connectionId"
    static let databaseKey = "database"

    static func userInfo(connectionId: UUID, database: String) -> [AnyHashable: Any] {
        [connectionIdKey: connectionId, databaseKey: database]
    }

    static func scope(of notification: Notification) -> (connectionId: UUID, database: String)? {
        guard let connectionId = notification.userInfo?[connectionIdKey] as? UUID,
              let database = notification.userInfo?[databaseKey] as? String
        else { return nil }
        return (connectionId, database)
    }
}

// Each mutation loads the ledger fresh, changes it, saves it, posts tableHealthHistoryDidChange and returns what it
// saved. A save that fails throws to the caller, which shows it.
@MainActor
protocol TableHealthHistoryStoring: AnyObject {
    func ledger(connectionId: UUID, database: String) throws -> TableHealthLedger
    // Moves on in the same main-actor call that renames or drops anything in the database's history, so a run that
    // read the catalog before it can tell.
    func generation(connectionId: UUID, database: String) -> Int
    // A run that started under another generation read names the history no longer has: it records nothing and gets
    // the current ledger back.
    func record(
        _ report: TableHealthReport,
        connectionId: UUID,
        database: String,
        generation: Int,
        at date: Date
    ) throws -> TableHealthLedger
    func setIgnored(
        _ ids: Set<TableHealthFindingID>,
        ignored: Bool,
        connectionId: UUID,
        database: String,
        at date: Date
    ) throws -> TableHealthLedger
    func clearResolved(connectionId: UUID, database: String) throws -> TableHealthLedger
}
