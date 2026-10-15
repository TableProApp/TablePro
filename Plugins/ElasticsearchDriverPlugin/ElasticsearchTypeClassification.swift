//
//  ElasticsearchTypeClassification.swift
//  ElasticsearchDriverPlugin
//

import Foundation
import TableProPluginKit

enum ElasticsearchTypeClassification {
    /// The SQL name the app classifies a mapping type by, where the mapping name is not one it
    /// reads. Unhinted, `long`, `short` and `date_nanos` classify as text: a cleared cell was then
    /// written as `""`, which the field's mapping refuses, and the grid sorted the numbers as text.
    static func classificationName(for mappingType: String) -> String? {
        switch mappingType {
        case "long", "unsigned_long": return "BIGINT"
        case "short": return "SMALLINT"
        case "byte": return "TINYINT"
        case "token_count": return "INTEGER"
        case "half_float", "scaled_float": return "FLOAT"
        case "date_nanos": return "TIMESTAMP"
        default: return nil
        }
    }

    /// The result's columns as `fetchColumns` describes them, carrying the hints above.
    static func columnMeta(columns: [String], typeNames: [String]) -> [PluginColumnInfo] {
        zip(columns, typeNames).map { column, typeName in
            let isID = column == ElasticsearchMappingFlattener.idColumn
            return PluginColumnInfo(
                name: column,
                dataType: typeName,
                isNullable: !isID,
                isPrimaryKey: isID,
                generationExpression: nil,
                generationKind: nil,
                ddlSpelling: nil,
                ddlDefault: nil,
                ddlGenerationExpression: nil,
                ddlCollation: nil,
                classificationTypeName: classificationName(for: typeName)
            )
        }
    }
}
