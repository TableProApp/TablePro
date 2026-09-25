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

/// A statement that failed after it had already switched database.
///
/// `use("b")` rebinds the shell's `db` and the host the moment it runs, so a statement that goes on
/// to throw has still moved the shell. The driver has to move with it, or its idea of the current
/// database stays behind and the next save for the old database skips the rebind and runs against
/// the new one.
struct MongoScriptStatementFailure: Error, LocalizedError {
    let underlying: Error
    let databaseSwitch: String

    var errorDescription: String? { underlying.localizedDescription }

    static func carrying(_ error: Error, databaseSwitch: String?) -> Error {
        guard let databaseSwitch else { return error }
        return MongoScriptStatementFailure(underlying: error, databaseSwitch: databaseSwitch)
    }
}
