//
//  TypeWidthComparisonTests.swift
//  TableProTests
//
//  What a type change costs, read per engine. The MySQL cases are pinned because the readings that
//  make PostgreSQL modifiers safe must not turn an unchanged or a widened MySQL column into a
//  refused statement.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Type width comparison")
struct TypeWidthComparisonTests {
    private func postgres(_ old: String, _ new: String) -> TypeWidthComparison.Outcome {
        TypeWidthComparison.classify(from: old, to: new, family: .postgres)
    }

    private func mysql(_ old: String, _ new: String) -> TypeWidthComparison.Outcome {
        TypeWidthComparison.classify(from: old, to: new, family: .mysql)
    }

    @Test("A shorter length narrows and a longer one widens")
    func lengthDecidesTheOutcome() {
        #expect(postgres("character varying(255)", "character varying(50)") == .narrowing)
        #expect(postgres("character varying(50)", "character varying(255)") == .widening)
        #expect(postgres("character varying(50)", "character varying(50)") == .equivalent)
    }

    @Test("Declaring a length on an unbounded type narrows it, and dropping one widens it")
    func boundedAndUnboundedAreNotTheSame() {
        #expect(postgres("character varying", "character varying(50)") == .narrowing)
        #expect(postgres("character varying(50)", "character varying") == .widening)
        #expect(postgres("numeric", "numeric(10,2)") == .narrowing)
        #expect(postgres("numeric(10,2)", "numeric") == .widening)
    }

    @Test("A decimal is judged on its decimal places and its integer digits separately")
    func decimalReadsBothParameters() {
        #expect(postgres("numeric(12,4)", "numeric(12,2)") == .narrowing)
        #expect(postgres("numeric(10,2)", "numeric(12,6)") == .narrowing)
        #expect(postgres("numeric(10,2)", "numeric(12,4)") == .widening)
        #expect(postgres("numeric(10,2)", "numeric(10,2)") == .equivalent)
        #expect(postgres("numeric(10)", "numeric(10,0)") == .equivalent)
    }

    @Test("Fractional seconds compare against the engine's own default")
    func fractionalSecondsFollowTheEngine() {
        #expect(postgres("timestamp(3) with time zone", "timestamp with time zone") == .widening)
        #expect(postgres("timestamp with time zone", "timestamp(3) with time zone") == .narrowing)
        #expect(mysql("datetime", "datetime(3)") == .widening)
        #expect(mysql("datetime(3)", "datetime") == .narrowing)
        #expect(mysql("datetime(6)", "datetime(6)") == .equivalent)
    }

    @Test("The words after the parentheses are part of the type name")
    func suffixIsPartOfTheBase() {
        #expect(postgres("timestamp(3) with time zone", "timestamp(3) without time zone") == .narrowing)
        #expect(postgres("character varying(20)[]", "character varying(20)") == .narrowing)
        #expect(postgres("character varying(20)[]", "character varying(50)[]") == .widening)
        #expect(postgres("character varying(50)[]", "character varying(20)[]") == .narrowing)
    }

    @Test("A different type name narrows, whatever its parameters say")
    func differentTypesNarrow() {
        #expect(postgres("status", "mood") == .narrowing)
        #expect(postgres("text", "character varying(50)") == .narrowing)
        #expect(postgres("integer", "bigint") == .narrowing)
    }

    @Test("A parameter that is not a width leaves the column unchanged")
    func unreadableParametersStayEquivalent() {
        #expect(postgres("public.geometry(Point,4326)", "public.geometry(Point,3857)") == .equivalent)
        #expect(postgres("public.geometry", "public.geometry(Point,4326)") == .equivalent)
        #expect(postgres("interval day to second(3)", "interval day to second(6)") == .widening)
    }

    @Test("A MySQL integer's display width is not a width")
    func mysqlDisplayWidthIsIgnored() {
        #expect(mysql("int(11)", "int") == .equivalent)
        #expect(mysql("int", "int(11)") == .equivalent)
        #expect(mysql("int(10) unsigned", "int unsigned") == .equivalent)
        #expect(mysql("bigint(20)", "bigint") == .equivalent)
    }

    /// `UNSIGNED` sits outside the parentheses, so it is part of the name and a change to it moves
    /// the column's range: MySQL documents an out-of-range value as an error under strict mode and
    /// as clipped without one. Reported before this only when the server spelled no display width,
    /// which is why the two directions disagreed between MySQL 8 and MariaDB.
    @Test("A MySQL signedness change is a type change, and ZEROFILL is not")
    func mysqlSignednessNarrows() {
        #expect(mysql("int(11)", "int(11) unsigned") == .narrowing)
        #expect(mysql("int unsigned", "int") == .narrowing)
        #expect(mysql("int(5) zerofill", "int(5)") == .equivalent)
        #expect(mysql("int(5)", "int(5) zerofill") == .equivalent)
    }

    @Test("A MySQL enum or set narrows only when a label goes")
    func mysqlLabelsDecideTheOutcome() {
        #expect(mysql("enum('a','b')", "enum('a','b','c')") == .widening)
        #expect(mysql("enum('a','b')", "enum('a','b')") == .equivalent)
        #expect(mysql("enum('a','b','c')", "enum('a','b')") == .narrowing)
        #expect(mysql("set('a','b')", "set('a','b','c')") == .widening)
        #expect(mysql("set('a','b','c')", "set('a','c')") == .narrowing)
    }

    @Test("The MySQL types a sync already allowed stay unchanged")
    func mysqlEveryDayChangesKeepTheirOutcome() {
        #expect(mysql("varchar(255)", "varchar(255)") == .equivalent)
        #expect(mysql("varchar(50)", "varchar(255)") == .widening)
        #expect(mysql("varchar(255)", "varchar(50)") == .narrowing)
        #expect(mysql("decimal(10,2)", "decimal(10,2)") == .equivalent)
        #expect(mysql("text", "text") == .equivalent)
        #expect(mysql("json", "json") == .equivalent)
        #expect(mysql("tinyint(1)", "tinyint(1)") == .equivalent)
        #expect(mysql("timestamp", "timestamp") == .equivalent)
    }
}
