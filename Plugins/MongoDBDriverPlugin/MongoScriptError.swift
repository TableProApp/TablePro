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
