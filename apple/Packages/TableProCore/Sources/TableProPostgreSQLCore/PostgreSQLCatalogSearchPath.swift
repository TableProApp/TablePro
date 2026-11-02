import Foundation
import TableProSQLQuoting

/// The `search_path` a driver-authored catalog statement runs under, set with `SET LOCAL` in the same query string so it
/// lasts only as long as the read.
///
/// PostgreSQL resolves a function or operator over every schema on the path, and a candidate that takes the call's
/// argument types exactly beats a `pg_catalog` one reached through a cast, wherever the two sit on the path. A
/// `pg_total_relation_size(oid)` or an `<>(oid, integer)` in a browsed schema would otherwise run with the reader's
/// privileges, the substitution of CVE-2018-1058. `pg_dump` runs with the same narrowed path for the same reason.
/// `pg_temp` is listed last so a temporary relation never shadows a catalog; functions and operators are never looked
/// up there.
///
/// `SET LOCAL` in the read's own query string makes the pair one implicit transaction, so the path is back as soon as
/// the read returns; inside a transaction the caller holds, the driver scopes it with a savepoint. `pg_catalog` rather
/// than an empty path: PostgreSQL 9.1 rejects `''` ("schema "" does not exist"), and `pg_catalog` deparses every user
/// relation with its schema all the same (measured identical output on 9.2, 9.3, 9.6 and 17).
nonisolated public enum PostgreSQLCatalogSearchPath {
    public static let pinned = "SET LOCAL search_path = pg_catalog, pg_temp; "

    // For a read the server deparses: `format_type` and the `pg_get_*def` functions write a name on the path bare.
    public static func relative(to schema: String) -> String {
        "SET LOCAL search_path = pg_catalog, \(SQLQuoting.identifier(schema)), pg_temp; "
    }
}
