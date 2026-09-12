//
//  StructureServerSupport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct StructureServerSupport: Equatable, Sendable {
    let unsupportedColumnFields: Set<StructureColumnField>
    let unsupportedIndexTypes: Set<String>

    static let unrestricted = StructureServerSupport(unsupportedColumnFields: [], unsupportedIndexTypes: [])

    init(unsupportedColumnFields: Set<StructureColumnField>, unsupportedIndexTypes: Set<String>) {
        self.unsupportedColumnFields = unsupportedColumnFields
        self.unsupportedIndexTypes = Set(unsupportedIndexTypes.map { $0.uppercased() })
    }

    init(driver: (any DatabaseDriver)?) {
        guard let driver else {
            self = .unrestricted
            return
        }
        self.init(
            unsupportedColumnFields: driver.unsupportedStructureColumnFields,
            unsupportedIndexTypes: driver.unsupportedIndexTypes
        )
    }

    @MainActor
    static func forConnection(_ connectionId: UUID) -> StructureServerSupport {
        StructureServerSupport(driver: DatabaseManager.shared.driver(for: connectionId))
    }

    func offers(_ field: StructureColumnField) -> Bool {
        !unsupportedColumnFields.contains(field)
    }

    func offeredIndexTypes(
        from types: [EditableIndexDefinition.IndexType]
    ) -> [EditableIndexDefinition.IndexType] {
        types.filter { !unsupportedIndexTypes.contains($0.rawValue.uppercased()) }
    }
}
