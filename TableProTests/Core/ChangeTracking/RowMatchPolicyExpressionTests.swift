//
//  RowMatchPolicyExpressionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct RowMatchPolicyExpressionTests {
    private let policy = RowMatchPolicy(textColumns: ["Notes"])

    @Test
    func aColumnOutsideThePolicyIsComparedAsItIs() {
        #expect(policy.matchExpression(for: "Name", quoted: "[Name]", value: .text("a"), databaseType: .mssql) == "[Name]")
    }

    @Test
    func sqlServerCastsTextToUnicodeAndBytesToBinary() {
        #expect(
            policy.matchExpression(for: "Notes", quoted: "[Notes]", value: .text("a"), databaseType: .mssql)
                == "CAST([Notes] AS NVARCHAR(MAX))"
        )
        #expect(
            policy.matchExpression(for: "Notes", quoted: "[Notes]", value: .bytes(Data([1])), databaseType: .mssql)
                == "CAST([Notes] AS VARBINARY(MAX))"
        )
    }

    @Test
    func mySQLComparesTheServersTextRendering() {
        #expect(
            policy.matchExpression(for: "Notes", quoted: "`Notes`", value: .text("1.1"), databaseType: .mysql)
                == "CONCAT(`Notes`)"
        )
    }

    @Test
    func sqlServerCuratesTheTypesItCannotCompareWithEquals() {
        let prefixes = PluginMetadataRegistry.mssqlRowMatchTextTypePrefixes
        #expect(prefixes.contains("NTEXT"))
        #expect(prefixes.contains("XML"))
        #expect(prefixes.contains("IMAGE"))
        #expect(!prefixes.contains("HIERARCHYID"))
    }
}
