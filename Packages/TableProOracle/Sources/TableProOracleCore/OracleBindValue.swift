import Foundation
import NIOCore
import OracleNIO

/// A positional parameter for ``OracleCoreConnection/executeQuery(_:binds:)``, bound to `:1` through `:n` in order.
public enum OracleBindValue: Sendable, Equatable {
    case text(String)
    case bytes(Data)
    case null
}

extension OracleBindValue {
    /// Oracle types a string literal as CHAR, which compares blank-padded: a `CHAR(10)` holding `abc` matches the
    /// literal `'abc'` but not a VARCHAR2 bind of `abc` (measured on Oracle 23ai). Text that fits a CHAR binds as
    /// CHAR, so a bind keeps the meaning of the literal it replaces.
    static let charByteLimit = 2_000

    static func bindings(for values: [OracleBindValue]) -> OracleBindings {
        var bindings = OracleBindings(capacity: values.count)
        for (index, value) in values.enumerated() {
            let name = String(index + 1)
            switch value {
            case .text(let text) where text.utf8.count <= charByteLimit:
                bindings.append(OracleCharBind(text: text), context: .default, bindName: name)
            case .text(let text):
                bindings.append(text, context: .default, bindName: name)
            case .bytes(let data):
                bindings.append(data, context: .default, bindName: name)
            case .null:
                bindings.appendNull(.varchar, bindName: name)
            }
        }
        return bindings
    }
}

/// Text bound as CHAR, with a buffer of exactly its UTF-8 bytes.
///
/// The driver's own CHAR type sizes a buffer at four bytes per unit of `size`, so 1,001 bytes of text would claim a
/// buffer over the 4,000-byte limit and go to the server as a LONG.
struct OracleCharBind: OracleEncodable {
    let text: String

    static var defaultOracleType: OracleDataType { .char }

    var oracleType: OracleDataType {
        OracleDataType(
            number: .char,
            name: "DB_TYPE_CHAR",
            oracleName: "CHAR",
            oracleType: .char,
            defaultSize: OracleBindValue.charByteLimit,
            csfrm: 1,
            bufferSizeFactor: 1
        )
    }

    /// Oracle reads empty text as NULL, and a bind still needs a buffer of at least one byte.
    var size: UInt32 {
        UInt32(max(text.utf8.count, 1))
    }

    func encode(into buffer: inout ByteBuffer, context: OracleEncodingContext) {
        ByteBuffer(string: text).encode(into: &buffer, context: context)
    }

    // The value writes its own length, as `ByteBuffer` does; the protocol names this requirement.
    // swiftlint:disable:next identifier_name
    func _encodeRaw(into buffer: inout ByteBuffer, context: OracleEncodingContext) {
        encode(into: &buffer, context: context)
    }
}
