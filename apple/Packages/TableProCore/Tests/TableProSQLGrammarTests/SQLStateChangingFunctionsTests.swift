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
        "sql_text_runners": SQLStateChangingFunctions.sqlTextRunners,
        "scheduled_jobs": SQLStateChangingFunctions.scheduledJobs,
        "hypertables_and_chunks": SQLStateChangingFunctions.hypertablesAndChunks,
        "roles_and_grants": SQLStateChangingFunctions.rolesAndGrants,
        "duckdb_calls": SQLStateChangingFunctions.duckDBCalls,
        "duckdb_call_families": Set(SQLStateChangingFunctions.duckDBCallFamilies),
        "duckdb_destructive_call_families": Set(SQLStateChangingFunctions.duckDBDestructiveCallFamilies)
    ]

    @Test("Each family lists the names the Linux app lists")
    func familiesMatchTheSharedNames() throws {
        let data = try Data(contentsOf: Self.sharedNames)
        let shared = try JSONDecoder().decode([String: [String]].self, from: data)
        let sharedFamilies = shared.mapValues { Set($0) }
        let everyEngine = Set(shared.filter { !$0.key.hasPrefix("duckdb_") }.values.joined())
        #expect(Self.families == sharedFamilies)
        #expect(SQLStateChangingFunctions.names == everyEngine)
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

    @Test("A MotherDuck md_ or __md_ name is a DuckDB call in any case", arguments: [
        "md_drop_database", "MD_CREATE_DATABASE", "__md_force_detach", "md_list_databases"
    ])
    func motherDuckFamilyIsADuckDBCall(name: String) {
        #expect(SQLStateChangingFunctions.isDuckDBCall(name))
        #expect(!SQLStateChangingFunctions.contains(name))
    }

    @Test("A name that only holds md_ is not a DuckDB call", arguments: ["get_md_token", "cmd_run", "md"])
    func lookalikeOfMotherDuckFamilyIsNotADuckDBCall(name: String) {
        #expect(!SQLStateChangingFunctions.isDuckDBCall(name))
    }

    @Test("A MotherDuck drop or delete name is a destructive DuckDB call in any case", arguments: [
        "md_drop_database", "MD_DROP_DATABASE_SHARE", "md_delete_dive"
    ])
    func motherDuckDropIsADestructiveCall(name: String) {
        #expect(SQLStateChangingFunctions.isDuckDBDestructiveCall(name))
    }

    @Test("Any other MotherDuck name is not a destructive call", arguments: [
        "md_create_database", "md_list_databases", "md_dropped", "__md_force_detach"
    ])
    func otherMotherDuckNamesAreNotDestructive(name: String) {
        #expect(!SQLStateChangingFunctions.isDuckDBDestructiveCall(name))
    }
}
