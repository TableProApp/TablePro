//
//  PluginFieldRendering.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
enum PluginFieldRendering {
    static func visibleFields(
        for type: DatabaseType,
        section: FieldSection,
        values: [String: String]
    ) -> [ConnectionField] {
        let fields = PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == section }
        return fields.filter { isFieldVisible($0, type: type, values: values) }
    }

    static func isFieldVisible(
        _ field: ConnectionField,
        type: DatabaseType,
        values: [String: String]
    ) -> Bool {
        PluginManager.shared.additionalConnectionFields(for: type)
            .isVisible(field, forValues: values)
    }

    static func defaultFieldValue(
        for fieldId: String,
        type: DatabaseType
    ) -> String {
        let registry = PluginManager.shared.additionalConnectionFields(for: type)
        return registry.first { $0.id == fieldId }?.defaultValue ?? ""
    }
}
