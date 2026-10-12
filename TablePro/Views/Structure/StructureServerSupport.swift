//
//  StructureServerSupport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct StructureServerSupport: Equatable, Sendable {
    let unsupportedColumnFields: Set<StructureColumnField>
    let unsupportedIndexTypes: Set<String>

    /// Why this server has no check constraints, even though the engine does. The engine's
    /// capability flags describe its newest release, and MySQL before 8.0.16 and MariaDB before
    /// 10.2.1 accept a `CHECK` clause and discard it.
    let checkConstraintRefusal: String?

    static let unrestricted = StructureServerSupport(unsupportedColumnFields: [], unsupportedIndexTypes: [])

    init(
        unsupportedColumnFields: Set<StructureColumnField>,
        unsupportedIndexTypes: Set<String>,
        checkConstraintRefusal: String? = nil
    ) {
        self.unsupportedColumnFields = unsupportedColumnFields
        self.unsupportedIndexTypes = Set(unsupportedIndexTypes.map { $0.uppercased() })
        self.checkConstraintRefusal = checkConstraintRefusal
    }

    init(driver: (any DatabaseDriver)?) {
        guard let driver else {
            self = .unrestricted
            return
        }
        self.init(
            unsupportedColumnFields: driver.unsupportedStructureColumnFields,
            unsupportedIndexTypes: driver.unsupportedIndexTypes,
            checkConstraintRefusal: driver.checkConstraintRefusal
        )
    }

    @MainActor
    static func forConnection(_ connectionId: UUID) -> StructureServerSupport {
        StructureServerSupport(driver: DatabaseManager.shared.driver(for: connectionId))
    }

    func offers(_ field: StructureColumnField) -> Bool {
        !unsupportedColumnFields.contains(field)
    }

    /// Exhaustive on purpose: a new tab has to state whether this server can refuse it.
    func offers(_ tab: StructureTab) -> Bool {
        switch tab {
        case .checkConstraints:
            return checkConstraintRefusal == nil
        case .columns, .indexes, .foreignKeys, .triggers, .ddl, .parts:
            return true
        }
    }

    func offeredIndexTypes(
        from types: [EditableIndexDefinition.IndexType]
    ) -> [EditableIndexDefinition.IndexType] {
        types.filter { !unsupportedIndexTypes.contains($0.rawValue) }
    }

    /// The Type list for one index: the known types this server offers, then the index's own type
    /// where it is not among them. A `CLUSTERED`, `DATA_SKIPPING` or `HNSW` row otherwise holds a
    /// value no menu item matches, and the inspector's picker shows nothing selected.
    func indexTypeChoices(
        keeping current: EditableIndexDefinition.IndexType
    ) -> [EditableIndexDefinition.IndexType] {
        let offered = offeredIndexTypes(from: EditableIndexDefinition.IndexType.knownTypes)
        return offered.contains(current) ? offered : offered + [current]
    }
}
