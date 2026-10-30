import Foundation
import TableProPluginKit
import Testing

private struct ReadFailure: Error {}

// The connection's foreign_keys as each statement leaves it, and the read-back that follows the assignment.
private final class ScriptedConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "1"
    private var reads = 0
    private let secondRead: Result<String, ReadFailure>
    private var log: [String] = []

    init(secondRead: Result<String, ReadFailure>) {
        self.secondRead = secondRead
    }

    var foreignKeys: String { lock.withLock { value } }
    var statements: [String] { lock.withLock { log } }

    func execute(_ query: String) throws -> PluginQueryResult {
        try lock.withLock {
            log.append(query)
            switch query {
            case "PRAGMA foreign_keys = ON": value = "1"
            case "PRAGMA foreign_keys = OFF": value = "0"
            default:
                reads += 1
                let answer = reads == 2 ? try secondRead.get() : value
                return PluginQueryResult(
                    columns: ["foreign_keys"], columnTypeNames: [], rows: [[.text(answer)]], rowsAffected: 0, executionTime: 0
                )
            }
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
    }
}

struct SQLiteSessionScopeTests {
    @Test("A relax whose read-back fails turns foreign keys back on before it throws")
    func failedReadBackRestores() async {
        let connection = ScriptedConnection(secondRead: .failure(ReadFailure()))

        await #expect(throws: ReadFailure.self) {
            _ = try await SQLiteSessionScope.open(for: .relaxedForeignKeys) { try connection.execute($0) }
        }

        #expect(connection.foreignKeys == "1")
        #expect(connection.statements.last == "PRAGMA foreign_keys = ON")
    }

    @Test("A relax whose read-back is unreadable turns foreign keys back on and opens no scope")
    func unreadableReadBackRestores() async throws {
        let connection = ScriptedConnection(secondRead: .success("unknown"))

        let scope = try await SQLiteSessionScope.open(for: .relaxedForeignKeys) { try connection.execute($0) }

        #expect(scope == nil)
        #expect(connection.foreignKeys == "1")
    }
}
