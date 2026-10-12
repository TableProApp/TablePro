//
//  PostgreSQLColumnTypeSpelling.swift
//  PostgreSQLDriverPlugin
//
//  Which of a column's two type spellings is shown and which one is classified. Pure, so the split
//  is pinned by a test without loading the driver.
//

import Foundation
import TableProPluginKit

enum PostgreSQLColumnTypeSpelling {
    struct Resolution: Equatable {
        let dataType: String
        let classificationTypeName: String?
    }

    /// `declaredType` is what the column shows: `character varying(50)`, `numeric(10,2)`, an enum by
    /// its name, a type from another schema qualified.
    ///
    /// The hint is what the app classifies by, and it is set only where the declared spelling names
    /// no kind the app knows: a user-defined type, an array of one, and a domain, whose declared name
    /// says nothing about the integer or the enum underneath. A `pg_catalog` type needs none, because
    /// `format_type` and `information_schema.data_type` are the same word there with a modifier
    /// added, and the classifier reads the base name.
    static func resolve(
        declaredType: String?,
        informationSchemaType: String,
        domainName: String?,
        udtSchema: String?,
        resolved: PostgresColumnTypeResolver.Resolution
    ) -> Resolution {
        guard let declaredType = declaredType?.nilIfEmpty else {
            return Resolution(dataType: resolved.dataType, classificationTypeName: nil)
        }
        return Resolution(
            dataType: declaredType,
            classificationTypeName: classificationTypeName(
                informationSchemaType: informationSchemaType,
                domainName: domainName,
                udtSchema: udtSchema,
                resolved: resolved
            )
        )
    }

    private static func classificationTypeName(
        informationSchemaType: String,
        domainName: String?,
        udtSchema: String?,
        resolved: PostgresColumnTypeResolver.Resolution
    ) -> String? {
        if domainName?.nilIfEmpty != nil { return resolved.dataType }
        switch informationSchemaType.uppercased() {
        case userDefinedType:
            return resolved.dataType
        case arrayType:
            return isCatalogElementArray(udtSchema: udtSchema, resolved: resolved) ? nil : resolved.dataType
        default:
            return nil
        }
    }

    /// An array of a `pg_catalog` base type, where `text[]` and `character varying(20)[]` classify
    /// alike. An array of anything else keeps the hint: an enum array carries its labels, and an
    /// array of a range or a composite is the resolver's own `ARRAY`, which the app reads as JSON.
    private static func isCatalogElementArray(
        udtSchema: String?,
        resolved: PostgresColumnTypeResolver.Resolution
    ) -> Bool {
        udtSchema == catalogSchema && resolved.dataType.uppercased() != arrayType
    }

    private static let userDefinedType = "USER-DEFINED"
    private static let arrayType = "ARRAY"
    private static let catalogSchema = "pg_catalog"
}
