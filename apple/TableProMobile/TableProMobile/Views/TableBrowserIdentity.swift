import TableProModels

// A database switch keeps the selection when the new catalog holds an equal table, so the database is part of the identity.
nonisolated struct TableBrowserIdentity: Hashable {
    let table: TableInfo?
    let database: String

    init(_ table: TableInfo?, _ database: String) {
        self.table = table
        self.database = database
    }
}
