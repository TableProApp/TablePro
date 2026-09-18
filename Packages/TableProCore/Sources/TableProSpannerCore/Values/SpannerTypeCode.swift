import Foundation

internal enum SpannerTypeCode {
    static let bool = "BOOL"
    static let int64 = "INT64"
    static let float64 = "FLOAT64"
    static let float32 = "FLOAT32"
    static let numeric = "NUMERIC"
    static let string = "STRING"
    static let bytes = "BYTES"
    static let json = "JSON"
    static let array = "ARRAY"
    static let structure = "STRUCT"
    static let pgJSONBAnnotation = "PG_JSONB"

    static func isFloat(_ code: String) -> Bool {
        code == float64 || code == float32
    }

    static func isExactNumber(_ code: String) -> Bool {
        code == int64 || code == numeric
    }
}
