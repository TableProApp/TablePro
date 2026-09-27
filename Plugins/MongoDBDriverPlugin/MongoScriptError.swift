import Foundation

/// What the script layer throws.
///
/// Separate from `MongoDBError` so the parts that build commands and read cursor options depend on
/// nothing but Foundation: the layer that talks to libmongoc maps this at its boundary, and
/// everything above it can be tested without a database.
struct MongoScriptError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

/// A statement that failed after it had already changed something outside itself.
///
/// `use("b")` rebinds the shell's `db` and the host the moment it runs, so a statement that goes on
/// to throw has still moved the shell. The driver has to move with it, or its idea of the current
/// database stays behind and the next save for the old database skips the rebind and runs against
/// the new one.
///
/// Writes are the other thing a failure cannot take back, so the documents the statement had
/// already changed travel with the error to the one place its message is built.
struct MongoScriptStatementFailure: Error, LocalizedError {
    let underlying: Error
    let databaseSwitch: String?
    let writes: MongoWriteLedger

    var errorDescription: String? {
        writes.reportedMessage(code: 0, message: underlying.localizedDescription, failedWrite: nil, maxTimeMS: nil)
    }

    static func carrying(_ error: Error, databaseSwitch: String?, writes: MongoWriteLedger) -> Error {
        guard databaseSwitch != nil || !writes.isEmpty else { return error }
        return MongoScriptStatementFailure(underlying: error, databaseSwitch: databaseSwitch, writes: writes)
    }
}
