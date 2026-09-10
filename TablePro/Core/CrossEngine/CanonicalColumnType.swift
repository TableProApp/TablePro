//
//  CanonicalColumnType.swift
//  TablePro
//
//  One vocabulary every engine's column types can be said in.
//
//  `PluginColumnKind` has five cases and `ColumnType` is documented as
//  display-only, and neither keeps a length, a precision or a time zone. Both
//  are enough to decide how to draw a cell and neither is enough to write a
//  `CREATE TABLE` for a different engine, which is why a copy across engines
//  was refused rather than approximated. This is the third vocabulary and the
//  only one that carries what DDL needs.
//
//  It is deliberately not a superset of every engine's type system. A type no
//  family here can express arrives as `.unsupported` carrying the source's own
//  spelling, so the renderer can say what it could not translate instead of
//  guessing a shape for it.
//

import Foundation

/// What a column holds, said without naming an engine.
internal enum CanonicalTypeKind: Hashable, Sendable {
    case boolean
    /// Width in bytes, which is what decides the target spelling: 1 is a MySQL `TINYINT` and a
    /// PostgreSQL `SMALLINT`, and no engine has a type for every width.
    case integer(bytes: Int)
    case decimal(precision: Int?, scale: Int?)
    case floatingPoint(bits: Int)
    case text(length: Int?, isFixed: Bool)
    case binary(length: Int?, isFixed: Bool)
    case date
    case time(precision: Int?, hasTimeZone: Bool)
    case timestamp(precision: Int?, hasTimeZone: Bool)
    case interval
    case uuid
    case json
    case xml
    /// Carries its labels because every engine that lacks `ENUM` needs them to size the text
    /// column that replaces it, and MySQL needs them to write the type back out.
    case enumeration(values: [String])
    case bitString(length: Int?)
    case money
    case spatial
    indirect case array(element: CanonicalTypeKind)
    case unsupported
}

internal struct CanonicalColumnType: Hashable, Sendable {
    internal let kind: CanonicalTypeKind
    /// MySQL's own modifier. Kept beside the kind rather than inside it because it doubles the
    /// integer cases for one engine, and because it is the fact that forces a widening on every
    /// other engine rather than a different type.
    internal let isUnsigned: Bool
    /// Exactly what the source called it, so a refusal can quote the user's own type name.
    internal let sourceSpelling: String

    internal init(kind: CanonicalTypeKind, isUnsigned: Bool = false, sourceSpelling: String) {
        self.kind = kind
        self.isUnsigned = isUnsigned
        self.sourceSpelling = sourceSpelling
    }
}

/// How close a rendered spelling is to what the source held.
///
/// Ordered so a table's worst column decides what the review step says about the table.
internal enum CanonicalTypeFidelity: Int, Comparable, Sendable {
    /// The target has the same type. Nothing to tell the user.
    case exact
    /// The target has no type this narrow, so a wider one is used. Every source value still fits.
    case widened
    /// The target has nothing equivalent and a different shape is used instead. Values survive as
    /// text, constraints and semantics do not.
    case approximated
    /// Nothing sensible to write. The column is left out.
    case unsupported

    internal static func < (lhs: CanonicalTypeFidelity, rhs: CanonicalTypeFidelity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

internal struct RenderedColumnType: Sendable {
    internal let spelling: String
    internal let fidelity: CanonicalTypeFidelity
    /// Why it is not exact, in the user's words. Nil when it is.
    internal let reason: String?

    internal init(spelling: String, fidelity: CanonicalTypeFidelity = .exact, reason: String? = nil) {
        self.spelling = spelling
        self.fidelity = fidelity
        self.reason = reason
    }
}
