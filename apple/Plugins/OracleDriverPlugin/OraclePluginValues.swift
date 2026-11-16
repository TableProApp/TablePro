//
//  OraclePluginValues.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

nonisolated extension OracleRawCell {
    var asPluginCell: PluginCellValue {
        switch self {
        case .null: return .null
        case .string(let value): return .text(value)
        case .bytes(let data): return .bytes(data)
        }
    }
}

nonisolated extension PluginCellValue {
    var oracleBindValue: OracleBindValue {
        switch self {
        case .null: return .null
        case .text(let value): return .text(value)
        case .bytes(let data): return .bytes(data)
        }
    }
}

nonisolated extension OracleColumnRow {
    var pluginColumnInfo: PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: displayType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: nil,
            identityKind: identityGeneration.map(\.identityKind),
            isGenerated: isVirtual,
            allowedValues: nil,
            generationExpression: generationExpression,
            generationKind: isVirtual ? .virtual : nil,
            ddlSpelling: OracleTypeCatalog.ddlSpelling(forDeclaredType: displayType),
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: classificationTypeName
        )
    }
}

nonisolated extension OracleIdentityGeneration {
    var identityKind: IdentityKind {
        switch self {
        case .always: return .always
        case .byDefault: return .byDefault
        }
    }
}
