//
//  CassandraObjectTextTests.swift
//  TableProTests
//

import Foundation
import Testing

struct CassandraObjectTextTests {
    @Test("A trigger's DDL names its class as a string literal, and quotes its names")
    func triggerDefinitionRunsAsCQL() {
        let className = CassandraObjectQueries.triggerClass(fromOptions: "{class: com.example.Audit}")
        #expect(className == "com.example.Audit")

        let ddl = CassandraObjectQueries.triggerDefinition(
            keyspace: "Shop", table: "orders", name: "auditTrigger", className: "com.example.O'Neil"
        )
        #expect(ddl.contains(#"CREATE TRIGGER "auditTrigger" ON "Shop"."orders""#))
        #expect(ddl.contains("USING 'com.example.O''Neil';"))
    }

    @Test("A trigger with no class entry yields no class")
    func triggerWithoutClass() {
        #expect(CassandraObjectQueries.triggerClass(fromOptions: "{}") == nil)
        #expect(CassandraObjectQueries.triggerClass(fromOptions: nil) == nil)
    }

    @Test("A list splits only at commas outside a type's angle brackets")
    func typeListKeepsNestedTypes() {
        #expect(CassandraObjectQueries.elements(of: "[frozen<map<text, int>>, int]") == ["frozen<map<text, int>>", "int"])
        #expect(CassandraObjectQueries.elements(of: "[tuple<int, text>]") == ["tuple<int, text>"])
        #expect(CassandraObjectQueries.elements(of: "[]").isEmpty)
        #expect(CassandraObjectQueries.elements(of: nil).isEmpty)
    }

    @Test("A function signature pairs names with whole types, and quotes the names in DDL")
    func signaturePairsNamesWithTypes() {
        let shown = CassandraObjectQueries.signature(argumentNames: "[m, x]", argumentTypes: "[frozen<map<text, int>>, int]")
        let ddl = CassandraObjectQueries.signature(
            argumentNames: "[m, x]", argumentTypes: "[frozen<map<text, int>>, int]", quotingNames: true
        )

        #expect(shown == "(m frozen<map<text, int>>, x int)")
        #expect(ddl == #"("m" frozen<map<text, int>>, "x" int)"#)
    }

    @Test("Function and aggregate DDL quote the keyspace and names, so a mixed-case one survives replay")
    func routineDefinitionsQuoteNames() {
        let function = CassandraObjectQueries.functionDefinition(
            keyspace: "Shop", name: "MyFunc", signature: "()", returnType: "int", language: "java",
            body: "return 1;", calledOnNullInput: true
        )
        let aggregate = CassandraObjectQueries.aggregateDefinition(
            keyspace: "Shop", name: "Total", signature: "(int)", stateFunction: "Add", stateType: "int",
            finalFunction: nil
        )

        #expect(function.contains(#"CREATE OR REPLACE FUNCTION "Shop"."MyFunc"()"#))
        #expect(aggregate.contains(#"CREATE OR REPLACE AGGREGATE "Shop"."Total"(int)"#))
        #expect(aggregate.contains(#"SFUNC "Add""#))
        #expect(aggregate.hasSuffix(";"))
        #expect(!aggregate.contains("FINALFUNC"))
    }

    @Test("A duration is written the way Cassandra spells one")
    func durationText() {
        #expect(CassandraCellText.durationText(months: 14, days: 3, nanoseconds: 9_000_000_000 + 5_000_000) == "1y2mo3d9s5ms")
        #expect(CassandraCellText.durationText(months: 0, days: 0, nanoseconds: 3_723_000_000_001) == "1h2m3s1ns")
        #expect(CassandraCellText.durationText(months: 0, days: -2, nanoseconds: -3_600_000_000_000) == "-2d1h")
        #expect(CassandraCellText.durationText(months: 0, days: 0, nanoseconds: 0) == "0s")
    }

    @Test("A float vector shows its numbers; any other custom value shows its bytes")
    func customText() {
        let floats = Data([0x3F, 0x80, 0x00, 0x00, 0x40, 0x20, 0x00, 0x00])
        let vectorClass = "org.apache.cassandra.db.marshal.VectorType(org.apache.cassandra.db.marshal.FloatType,2)"
        let measuredClass = "org.apache.cassandra.db.marshal.VectorType(org.apache.cassandra.db.marshal.FloatType , 2)"

        #expect(CassandraCellText.customText(className: vectorClass, bytes: floats) == "[1.0, 2.5]")
        #expect(CassandraCellText.customText(className: measuredClass, bytes: floats) == "[1.0, 2.5]")
        #expect(CassandraCellText.customText(className: "com.example.Custom", bytes: Data([0xCA, 0xFE])) == "0xcafe")
        #expect(CassandraCellText.customText(className: nil, bytes: Data([0x01])) == "0x01")
    }
}
