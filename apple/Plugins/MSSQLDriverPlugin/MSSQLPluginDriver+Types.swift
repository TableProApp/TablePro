//
//  MSSQLPluginDriver+Types.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit

extension MSSQLPluginDriver {
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        try await exportCatalog.fetchUserDefinedTypes(schema: schema)
    }

    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        try await exportCatalog.fetchUserDefinedType(type)
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo) -> String? {
        "DROP TYPE \(MSSQLTypeDefinition.bracketed(effectiveSchema(type.schema))).\(MSSQLTypeDefinition.bracketed(type.name))"
    }
}
