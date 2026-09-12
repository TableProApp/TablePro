//
//  StructureEditEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One change the Structure tab can ask a server to make.
///
/// The vocabulary is per operation rather than per object because the server answers per operation.
/// Measured on PostgreSQL 17.11: a view takes `RENAME COLUMN`, `SET DEFAULT`, `DROP DEFAULT` and
/// `COMMENT ON COLUMN` and refuses `ADD COLUMN`, `SET NOT NULL`, `SET DATA TYPE`, `CREATE INDEX` and
/// every `ADD CONSTRAINT`, while a materialized view takes `CREATE INDEX` and refuses `SET DEFAULT`.
/// A single read-only flag for the whole object would withhold four edits that work and still offer
/// several the server always refuses.
enum StructureEditOperation: Sendable, Hashable, CaseIterable {
    case addColumn
    case dropColumn
    case renameColumn
    case setNotNull
    case dropNotNull
    case setDefault
    case dropDefault
    case changeColumnType
    /// The column attributes an engine can only change by rewriting the whole column definition:
    /// primary key, auto increment, on update, charset, collation and generated. One case rather
    /// than six, so none of them is ever gated through a proxy that means something else.
    case redefineColumn
    case addIndex
    case dropIndex
    case addForeignKey
    case dropForeignKey
    case addCheckConstraint
    case dropCheckConstraint
    case commentOnColumn
    case reorderColumns

    /// What the edit is about, which is what a refusal has to explain. A materialized view refuses
    /// `SET DEFAULT` and `ADD CONSTRAINT FOREIGN KEY` for two different reasons, and one sentence
    /// covering both would be true of neither.
    enum Subject: Sendable, Hashable {
        case columns
        case columnOrder
        case indexes
        case constraints
    }

    var subject: Subject {
        switch self {
        case .addColumn, .dropColumn, .renameColumn, .setNotNull, .dropNotNull, .setDefault,
             .dropDefault, .changeColumnType, .redefineColumn, .commentOnColumn:
            return .columns
        case .reorderColumns:
            return .columnOrder
        case .addIndex, .dropIndex:
            return .indexes
        case .addForeignKey, .dropForeignKey, .addCheckConstraint, .dropCheckConstraint:
            return .constraints
        }
    }
}

/// Which structure edits each kind of object accepts on one engine.
///
/// Curated per `DatabaseType` in `SchemaEditingSupport` rather than asked of a driver, because the
/// affordance has to be offered or withheld before the user starts filling a row in, and a
/// capability the app only learns from a failed statement is far too late for that.
struct StructureObjectEditMatrix: Sendable, Equatable {
    private let operationsByKind: [TableInfo.TableType: Set<StructureEditOperation>]

    init(_ operationsByKind: [TableInfo.TableType: Set<StructureEditOperation>]) {
        self.operationsByKind = operationsByKind
    }

    func operations(for kind: TableInfo.TableType) -> Set<StructureEditOperation> {
        operationsByKind[kind] ?? []
    }

    private static let everyOperation = Set(StructureEditOperation.allCases)

    /// The default for an engine nobody has curated: a real table takes every edit the engine's own
    /// flags allow, and no other kind takes any. Conservative on purpose. Offering an edit the
    /// server refuses costs the user a filled-in row and an error at Save; withholding one it would
    /// have taken costs a trip to the query editor.
    static let tablesOnly = StructureObjectEditMatrix([
        .table: everyOperation,
        .partitionedTable: everyOperation
    ])

    /// Measured against PostgreSQL 17.11, one statement per cell. A table and a partitioned table
    /// take all seventeen. A view and a materialized view differ on `SET DEFAULT` and on
    /// `CREATE INDEX`, which is why one row per kind is the only shape that works. A foreign table
    /// takes every column change and `ADD CHECK` but refuses `CREATE INDEX`, `FOREIGN KEY` and
    /// `UNIQUE`. A system table refuses everything with "permission denied: is a system catalog",
    /// and an external table is a Redshift Spectrum relation whose columns live in another catalog.
    static let postgreSQL = StructureObjectEditMatrix([
        .table: everyOperation,
        .partitionedTable: everyOperation,
        .view: [.renameColumn, .setDefault, .dropDefault, .commentOnColumn],
        .materializedView: [.renameColumn, .commentOnColumn, .addIndex, .dropIndex],
        .foreignTable: [
            .addColumn, .dropColumn, .renameColumn, .setNotNull, .dropNotNull, .setDefault,
            .dropDefault, .changeColumnType, .addCheckConstraint, .dropCheckConstraint,
            .commentOnColumn
        ],
        .systemTable: [],
        .externalTable: []
    ])
}

/// Whether the Structure tab may offer one edit right now, and what to say when it may not.
///
/// Mirrors `ForeignKeyEditAvailability` so every refusal in this tab carries its own sentence. A
/// control that dims without saying why reads as a broken app, and a control that stays enabled over
/// a statement the server always refuses is worse: the user fills the row in first.
enum StructureEditAvailability: Sendable, Equatable {
    case available

    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The single decision about which structure edits an object's kind accepts.
///
/// Pure, so the rule is testable without a connection, and ordered: an engine that cannot edit
/// structure at all says that first, then the object's kind, then the engine's own statement for the
/// operation. Reading the kind as one `isView` Bool is the defect this replaces, because
/// `TableInfo.TableType.allowsRowEditing` is true for a materialized view, so the Structure tab
/// offered `ADD COLUMN`, `SET NOT NULL`, type changes and constraint edits that PostgreSQL always
/// refuses. (#2726)
enum StructureEditEligibility {
    static func allows(
        _ operation: StructureEditOperation,
        on kind: TableInfo.TableType,
        matrix: StructureObjectEditMatrix
    ) -> Bool {
        matrix.operations(for: kind).contains(operation)
    }

    /// Why this kind of object refuses the operation, and nil when it does not.
    ///
    /// Handed to `ForeignKeyEditPolicy` and `ColumnReorderPolicy`, which used to decide it from an
    /// `isTable` Bool and then name a view in the sentence. Only the matrix knows which of seven
    /// kinds is in front of the user, so only the matrix can word the refusal.
    static func refusalReason(
        for operation: StructureEditOperation,
        on kind: TableInfo.TableType,
        matrix: StructureObjectEditMatrix
    ) -> String? {
        guard !allows(operation, on: kind, matrix: matrix) else { return nil }
        return reason(operation.subject, kind)
    }

    static func resolve(
        _ operation: StructureEditOperation,
        on kind: TableInfo.TableType,
        matrix: StructureObjectEditMatrix,
        engineAllows: Bool,
        engineName: String,
        canEditSchema: Bool
    ) -> StructureEditAvailability {
        guard canEditSchema else {
            return .unavailable(
                reason: String(format: String(localized: "%@ cannot edit a table's structure."), engineName)
            )
        }
        if let refusal = refusalReason(for: operation, on: kind, matrix: matrix) {
            return .unavailable(reason: refusal)
        }
        guard engineAllows else {
            return .unavailable(reason: engineReason(operation.subject, engineName))
        }
        return .available
    }

    /// Every field of the Columns grid this kind of object lets the user change.
    ///
    /// Keyed by field rather than by row, because the refusal is per column attribute: PostgreSQL
    /// takes a view's `RENAME COLUMN` and `SET DEFAULT` and refuses its `SET NOT NULL` and
    /// `SET DATA TYPE`, so Name and Default stay editable while Nullable and Type lock.
    static func editableFields(
        on kind: TableInfo.TableType,
        matrix: StructureObjectEditMatrix
    ) -> Set<StructureColumnField> {
        let allowed = matrix.operations(for: kind)
        return Set(StructureColumnField.allCases.filter { field in
            !operations(expressing: field).isDisjoint(with: allowed)
        })
    }

    static func allowsAnyEdit(on kind: TableInfo.TableType, matrix: StructureObjectEditMatrix) -> Bool {
        !matrix.operations(for: kind).isEmpty
    }

    /// The operations that can express a change to this field. A field with more than one is
    /// editable as soon as either statement is accepted, because the grid cannot know in advance
    /// which direction the user will toggle it.
    private static func operations(expressing field: StructureColumnField) -> Set<StructureEditOperation> {
        switch field {
        case .name: return [.renameColumn]
        case .type: return [.changeColumnType]
        case .nullable: return [.setNotNull, .dropNotNull]
        case .defaultValue: return [.setDefault, .dropDefault]
        case .comment: return [.commentOnColumn]
        case .onUpdate, .primaryKey, .autoIncrement, .charset, .collation, .generated,
             .generationExpression:
            return [.redefineColumn]
        @unknown default:
            /// A field this build does not know is gated behind a full column rewrite, which is the
            /// narrowest answer available and therefore the safe one.
            return [.redefineColumn]
        }
    }

    /// Why the engine cannot make the change even on a plain table. Worded per subject rather than
    /// once, because "cannot edit a table's structure" over a dimmed **Add Index** tells the reader
    /// nothing they could act on.
    private static func engineReason(_ subject: StructureEditOperation.Subject, _ engineName: String) -> String {
        switch subject {
        case .columns:
            return String(format: String(localized: "%@ cannot make this change to a table's columns."), engineName)
        case .columnOrder:
            return String(
                format: String(localized: "%@ cannot change the order of a table's columns."),
                engineName
            )
        case .indexes:
            return String(format: String(localized: "%@ cannot add or remove a table's indexes."), engineName)
        case .constraints:
            return String(format: String(localized: "%@ cannot add or remove a table's constraints."), engineName)
        }
    }

    private static func reason(_ subject: StructureEditOperation.Subject, _ kind: TableInfo.TableType) -> String {
        let noun = objectNoun(kind)
        switch subject {
        case .columns:
            return String(format: String(localized: "%@ does not accept this column change."), noun)
        case .columnOrder:
            return String(format: String(localized: "%@ has no column order of its own to change."), noun)
        case .indexes:
            return String(format: String(localized: "%@ cannot have indexes."), noun)
        case .constraints:
            return String(format: String(localized: "%@ cannot have constraints."), noun)
        }
    }

    /// The object's kind as the subject of a sentence, because every refusal above names it. The
    /// sidebar's own label is a bare noun ("View"), which reads as a heading rather than a sentence.
    private static func objectNoun(_ kind: TableInfo.TableType) -> String {
        switch kind {
        case .table: return String(localized: "A table")
        case .partitionedTable: return String(localized: "A partitioned table")
        case .view: return String(localized: "A view")
        case .materializedView: return String(localized: "A materialized view")
        case .foreignTable: return String(localized: "A foreign table")
        case .systemTable: return String(localized: "A system table")
        case .externalTable: return String(localized: "An external table")
        }
    }
}
