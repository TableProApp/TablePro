import Foundation

/// Decimal128 carries 34 significant decimal digits. Reading it as a `Double` keeps 17, so the
/// digits are held as text and only ever rendered or written back from that text.
struct MongoDBDecimal128: Sendable, Hashable, CustomStringConvertible {
    static let columnTypeName = "DECIMAL"

    let digits: String

    init(digits: String) {
        self.digits = digits
    }

    var description: String { digits }
}
