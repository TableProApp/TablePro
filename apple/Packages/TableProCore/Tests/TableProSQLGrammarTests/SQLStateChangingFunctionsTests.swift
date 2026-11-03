import Foundation
@testable import TableProSQLGrammar
import Testing

// The Linux app keeps its own copy of this table, and both test suites compare theirs with one file.
struct SQLStateChangingFunctionsTests {
    private static let sharedNames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("core/crates/core/tests/fixtures/state_changing_functions.json")

    private static let families: [String: Set<String>] = [
        "server_signals": SQLStateChangingFunctions.serverSignals,
        "session_control": SQLStateChangingFunctions.sessionControl,
        "recovery_and_backup": SQLStateChangingFunctions.recoveryAndBackup,
        "replication": SQLStateChangingFunctions.replication,
        "sequences": SQLStateChangingFunctions.sequences,
        "advisory_locks": SQLStateChangingFunctions.advisoryLocks,
        "settings_and_statistics": SQLStateChangingFunctions.settingsAndStatistics,
        "large_objects": SQLStateChangingFunctions.largeObjects,
        "files_and_extensions": SQLStateChangingFunctions.filesAndExtensions,
        "catalog_and_storage": SQLStateChangingFunctions.catalogAndStorage,
        "index_maintenance": SQLStateChangingFunctions.indexMaintenance,
        "sql_text_runners": SQLStateChangingFunctions.sqlTextRunners
    ]

    @Test("Each family lists the names the Linux app lists")
    func familiesMatchTheSharedNames() throws {
        let data = try Data(contentsOf: Self.sharedNames)
        let shared = try JSONDecoder().decode([String: [String]].self, from: data)
        let sharedFamilies = shared.mapValues { Set($0) }
        let everyName = Set(shared.values.joined())
        #expect(Self.families == sharedFamilies)
        #expect(SQLStateChangingFunctions.names == everyName)
    }

    @Test("A listed name matches in any case, under sys_, and with a letter MariaDB folds", arguments: [
        "relea\u{017F}e_lock", "RELEA\u{017F}E_ALL_LOCK\u{017F}", "PG_TERMINATE_BACKEND", "sys_terminate_backend"
    ])
    func foldedNameIsListed(name: String) {
        #expect(SQLStateChangingFunctions.contains(name))
    }

    @Test("A name that only looks like a listed one is not listed", arguments: [
        "currval", "query_to_xmlschema", "lo_get", "sys_backend_pid"
    ])
    func otherNamesAreNotListed(name: String) {
        #expect(!SQLStateChangingFunctions.contains(name))
    }
}
