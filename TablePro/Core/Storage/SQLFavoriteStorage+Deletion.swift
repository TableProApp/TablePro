import Foundation
import SQLite3

internal extension SQLFavoriteStorage {
    func deleteFavorites(ids: [UUID]) -> [UUID: UUID]? {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let bindings = ids.map(\.uuidString)

        guard let connectionIds = connectionIds(
            of: "SELECT id, connection_id FROM favorites WHERE id IN (\(placeholders)) AND connection_id IS NOT NULL;",
            bindings: bindings
        ), run("DELETE FROM favorites WHERE id IN (\(placeholders));", bindings: bindings) else {
            return nil
        }
        return connectionIds
    }

    private func connectionIds(of sql: String, bindings: [String]) -> [UUID: UUID]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }

        var connectionIds: [UUID: UUID] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawId = sqlite3_column_text(statement, 0),
                      let rawConnectionId = sqlite3_column_text(statement, 1),
                      let id = UUID(uuidString: String(cString: rawId)),
                      let connectionId = UUID(uuidString: String(cString: rawConnectionId)) else { continue }
                connectionIds[id] = connectionId
            case SQLITE_DONE:
                return connectionIds
            default:
                return nil
            }
        }
    }
}
