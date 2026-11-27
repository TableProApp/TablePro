import Foundation

// Setting `session_replication_role` takes a superuser or a `SET` grant, and a bare refusal aborts the transaction it
// runs in. The block swallows the refusal and keeps the transaction, and an allowed `SET` outlives it (measured on
// 17.11 and 18.6).
nonisolated public enum PostgreSQLForeignKeyChecks {
    public static let disableStatements = [settingReplicationRole("replica")]
    public static let enableStatements = [settingReplicationRole("DEFAULT")]

    private static func settingReplicationRole(_ value: String) -> String {
        "DO $$ BEGIN SET session_replication_role = \(value); EXCEPTION WHEN insufficient_privilege THEN NULL; END $$"
    }
}
