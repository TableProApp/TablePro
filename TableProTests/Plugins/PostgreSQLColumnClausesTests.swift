//
//  PostgreSQLColumnClausesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLColumnClausesTests {
    private func column(
        dataType: String = "geometry",
        ddlSpelling: String? = nil,
        defaultValue: String? = nil,
        ddlDefault: String? = nil,
        generationExpression: String? = nil,
        ddlGenerationExpression: String? = nil,
        autoIncrement: Bool = false
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: "shape",
            dataType: dataType,
            defaultValue: defaultValue,
            autoIncrement: autoIncrement,
            generationExpression: generationExpression,
            generationKind: generationExpression == nil ? nil : .stored,
            ddlSpelling: ddlSpelling,
            ddlDefault: ddlDefault,
            ddlGenerationExpression: ddlGenerationExpression
        )
    }

    @Test("The server's type spelling is written, schema and modifier included")
    func writesServerTypeSpelling() {
        let type = PostgreSQLColumnClauses.type(for: column(ddlSpelling: "public.geometry(Point,4326)"))
        #expect(type == "public.geometry(Point,4326)")
    }

    @Test("An enum, a composite and a quoted type are written as the catalog spells them, never as the classified type")
    func writesCatalogSpellingOverClassifiedType() {
        let cases: [(dataType: String, ddlSpelling: String)] = [
            ("ENUM", "\"Mixed Case\".\"My Status\""),
            ("ENUM[]", "\"Mixed Case\".\"My Status\"[]"),
            ("addr", "public.addr"),
            ("ARRAY", "public.pair[]"),
            ("CHARACTER", "character(10)"),
            ("TEXT", "\"Mixed Case\".postal")
        ]
        for testCase in cases {
            let type = PostgreSQLColumnClauses.type(
                for: column(dataType: testCase.dataType, ddlSpelling: testCase.ddlSpelling)
            )
            #expect(type == testCase.ddlSpelling, "\(testCase.dataType)")
        }
    }

    @Test("A column with no catalog spelling writes its declared type")
    func fallsBackToDataType() {
        #expect(PostgreSQLColumnClauses.type(for: column(dataType: "VARCHAR(20)")) == "VARCHAR(20)")
    }

    @Test("An auto-increment column becomes a serial type from whichever spelling was chosen")
    func autoIncrementRewritesChosenSpelling() {
        let cases: [(dataType: String, ddlSpelling: String?, expected: String)] = [
            ("BIGINT", nil, "BIGSERIAL"),
            ("INT8", nil, "BIGSERIAL"),
            ("INTEGER", nil, "SERIAL"),
            ("BIGINT", "bigint", "BIGSERIAL"),
            ("INTEGER", "integer", "SERIAL")
        ]
        for testCase in cases {
            let type = PostgreSQLColumnClauses.type(
                for: column(dataType: testCase.dataType, ddlSpelling: testCase.ddlSpelling, autoIncrement: true)
            )
            #expect(type == testCase.expected, "\(testCase.dataType) / \(testCase.ddlSpelling ?? "nil")")
        }
    }

    @Test("An altered type takes the server's spelling and never a serial pseudo-type")
    func alteredTypeUsesSpellingWithoutSerial() {
        #expect(PostgreSQLColumnClauses.alteredType(for: column(dataType: "ENUM", ddlSpelling: "app.order_status")) == "app.order_status")
        #expect(PostgreSQLColumnClauses.alteredType(for: column(dataType: "BIGINT", autoIncrement: true)) == "BIGINT")
        #expect(PostgreSQLColumnClauses.alteredType(for: column(dataType: "TEXT")) == "TEXT")
    }

    @Test("A qualified default is written over the one read under the source's path")
    func writesQualifiedDefault() {
        let clause = PostgreSQLColumnClauses.defaultExpression(
            for: column(defaultValue: "'new'::status", ddlDefault: "'new'::public.status")
        )
        #expect(clause == "'new'::public.status")
    }

    @Test("A default with no qualified spelling is written as read")
    func defaultWithoutSpellingIsWrittenAsRead() {
        let clause = PostgreSQLColumnClauses.defaultExpression(
            for: column(defaultValue: "nextval('orders_id_seq'::regclass)")
        )
        #expect(clause == "nextval('orders_id_seq'::regclass)")
        #expect(PostgreSQLColumnClauses.defaultExpression(for: column()) == nil)
    }

    @Test("A generation expression prefers the qualified spelling and treats an empty one as none")
    func generationExpressionChoice() {
        let qualified = PostgreSQLColumnClauses.generationExpression(
            for: column(generationExpression: "st_x(shape)", ddlGenerationExpression: "public.st_x(shape)")
        )
        #expect(qualified == "public.st_x(shape)")
        #expect(PostgreSQLColumnClauses.generationExpression(for: column(generationExpression: "st_x(shape)")) == "st_x(shape)")
        #expect(PostgreSQLColumnClauses.generationExpression(for: column(generationExpression: "")) == nil)
    }
}
