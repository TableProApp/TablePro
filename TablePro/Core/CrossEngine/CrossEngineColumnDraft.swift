//
//  CrossEngineColumnDraft.swift
//  TablePro
//
//  One column between reading its source type and writing its target one.
//
//  A column's type is not decided by the column alone. A key over too many
//  bytes, or a row too wide for its engine, is a fact about the table, so the
//  translator renders every column first and lets the table-wide passes respell
//  the ones that do not fit before anything is written.
//

import Foundation

internal struct CrossEngineColumnDraft: Sendable {
    internal let name: String
    internal let isNullable: Bool
    internal let source: CanonicalColumnType
    internal private(set) var rendered: RenderedColumnType
    /// Read back out of the spelling, so a respelling changes what the coercer and the index
    /// translator see as well as what the DDL says.
    internal private(set) var targetKind: CanonicalTypeKind
    private let family: SQLTypeFamily

    internal init(
        name: String,
        isNullable: Bool,
        source: CanonicalColumnType,
        rendered: RenderedColumnType,
        family: SQLTypeFamily
    ) {
        self.name = name
        self.isNullable = isNullable
        self.source = source
        self.rendered = rendered
        self.family = family
        self.targetKind = SQLTypeParser.parse(rendered.spelling, family: family).kind
    }

    /// The reason is the new one, because the old one described a spelling that is no longer
    /// written. The fidelity is the worse of the two, so a column that already lost something does
    /// not read as merely widened.
    internal mutating func respell(_ spelling: String, fidelity: CanonicalTypeFidelity, reason: String) {
        rendered = RenderedColumnType(spelling: spelling, fidelity: max(fidelity, rendered.fidelity), reason: reason)
        targetKind = SQLTypeParser.parse(spelling, family: family).kind
    }
}
