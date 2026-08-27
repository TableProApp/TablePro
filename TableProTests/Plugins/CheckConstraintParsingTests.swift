//
//  CheckConstraintParsingTests.swift
//  TableProTests
//
//  Every expectation here is a measured server response, not a guess: PostgreSQL 17.11,
//  MariaDB 12.3.2 and SQLite 3.53.4/3.54.0 were probed directly.
//

import Foundation
import Testing

@Suite("PostgreSQL check constraint definitions")
struct PostgreSQLCheckConstraintDefinitionTests {
    @Test("the CHECK keyword and the parentheses PostgreSQL adds are removed")
    func stripsKeywordAndWrapper() {
        #expect(PostgreSQLCheckConstraintDefinition.expression(fromConstraintDef: "CHECK ((a > 0))") == "a > 0")
    }

    @Test("a multi-column check keeps both of its own parenthesised operands")
    func keepsInnerParenthesesOfMultiColumnCheck() {
        let definition = "CHECK (((a > 0) AND (char_length(b) < 10)))"
        #expect(
            PostgreSQLCheckConstraintDefinition.expression(fromConstraintDef: definition)
                == "(a > 0) AND (char_length(b) < 10)"
        )
    }

    @Test("NOT VALID is a flag on the constraint, not part of its expression")
    func dropsNotValidSuffix() {
        #expect(
            PostgreSQLCheckConstraintDefinition.expression(fromConstraintDef: "CHECK ((a < 1000)) NOT VALID")
                == "a < 1000"
        )
    }

    @Test("a parenthesis inside a string literal never ends the expression")
    func ignoresParenthesesInsideLiterals() {
        let definition = "CHECK (((status)::text = 'open (new)'::text))"
        #expect(
            PostgreSQLCheckConstraintDefinition.expression(fromConstraintDef: definition)
                == "(status)::text = 'open (new)'::text"
        )
    }

    @Test("an expression whose own parentheses do not wrap the whole thing is left alone")
    func leavesNonEnclosingParenthesesAlone() {
        #expect(
            PostgreSQLCheckConstraintDefinition.expression(fromConstraintDef: "CHECK ((a > 0) AND (b > 0))")
                == "(a > 0) AND (b > 0)"
        )
    }
}

@Suite("SQLite check constraint parsing")
struct SQLiteCheckConstraintParserTests {
    private let createStatement = """
        CREATE TABLE t (
          a INTEGER NOT NULL CHECK (a > 0),
          b TEXT,
          c INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL,
          d TEXT GENERATED ALWAYS AS (b || 'x') STORED,
          CONSTRAINT ck_multi CHECK (a > 0 AND length(b) < 10)
        , CONSTRAINT ck2 CHECK (a < 100))
        """

    @Test("a named table-level constraint is read with its full expression")
    func readsNamedTableConstraints() {
        let parsed = SQLiteCheckConstraintParser.constraints(inCreateStatement: createStatement)
        #expect(parsed.map(\.name) == ["ck_multi", "ck2"])
        #expect(parsed.first?.expression == "a > 0 AND length(b) < 10")
    }

    @Test("a multi-column check is one constraint, not one per column")
    func multiColumnCheckIsOneRow() {
        let parsed = SQLiteCheckConstraintParser.constraints(inCreateStatement: createStatement)
        #expect(parsed.filter { $0.name == "ck_multi" }.count == 1)
    }

    @Test("an unnamed column-level check is skipped, because DROP CONSTRAINT needs a name")
    func skipsUnnamedColumnChecks() {
        let parsed = SQLiteCheckConstraintParser.constraints(inCreateStatement: createStatement)
        #expect(!parsed.contains { $0.expression == "a > 0" })
    }

    @Test("a comma inside an expression does not split the constraint")
    func commaInsideExpressionDoesNotSplit() {
        let statement = "CREATE TABLE t (a INT, CONSTRAINT ck CHECK (a IN (1, 2, 3)))"
        let parsed = SQLiteCheckConstraintParser.constraints(inCreateStatement: statement)
        #expect(parsed.count == 1)
        #expect(parsed.first?.expression == "a IN (1, 2, 3)")
    }

    @Test("a quoted constraint name is unquoted")
    func unquotesConstraintName() {
        let statement = #"CREATE TABLE t (a INT, CONSTRAINT "my check" CHECK (a > 0))"#
        #expect(SQLiteCheckConstraintParser.constraints(inCreateStatement: statement).first?.name == "my check")
    }

    @Test("generation expressions are read per column, in both spellings")
    func readsGenerationExpressions() {
        let expressions = SQLiteCheckConstraintParser.generationExpressions(inCreateStatement: createStatement)
        #expect(expressions["c"] == "a * 2")
        #expect(expressions["d"] == "b || 'x'")
    }

    @Test("the short AS spelling is recognised too")
    func readsShortGenerationSpelling() {
        let statement = "CREATE TABLE t (a INT, c INT AS (a + 1) STORED)"
        #expect(SQLiteCheckConstraintParser.generationExpressions(inCreateStatement: statement)["c"] == "a + 1")
    }

    @Test("a plain column reports no generation expression")
    func plainColumnHasNoExpression() {
        let expressions = SQLiteCheckConstraintParser.generationExpressions(inCreateStatement: createStatement)
        #expect(expressions["a"] == nil)
        #expect(expressions["b"] == nil)
    }
}

@Suite("MySQL server version floors")
struct MySQLServerVersionTests {
    @Test("MySQL gains CHECK_CONSTRAINTS at 8.0.16, not before")
    func mysqlCheckFloor() {
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: "5.7.44", isMariaDB: false))
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: "8.0.15", isMariaDB: false))
        #expect(MySQLServerVersion.hasCheckConstraints(banner: "8.0.16", isMariaDB: false))
        #expect(MySQLServerVersion.hasCheckConstraints(banner: "8.4.0", isMariaDB: false))
    }

    @Test("MariaDB gains them at 10.2.1 and reports its own banner")
    func mariadbCheckFloor() {
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: "10.1.48-MariaDB", isMariaDB: true))
        #expect(MySQLServerVersion.hasCheckConstraints(banner: "10.2.1-MariaDB", isMariaDB: true))
        #expect(MySQLServerVersion.hasCheckConstraints(banner: "12.3.2-MariaDB", isMariaDB: true))
    }

    @Test("MariaDB 10.1 has generated columns but no GENERATION_EXPRESSION column")
    func generationExpressionFloor() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "10.1.48-MariaDB", isMariaDB: true))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "10.2.0-MariaDB", isMariaDB: true))
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "5.7.5", isMariaDB: false))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "5.7.6", isMariaDB: false))
    }

    @Test("an unreadable banner is treated as unsupported rather than assumed modern")
    func unknownBannerIsUnsupported() {
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: nil, isMariaDB: false))
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: "unknown", isMariaDB: false))
    }
}

@Suite("MSSQL check constraint definitions")
struct MSSQLCheckConstraintDefinitionTests {
    @Test("the wrapping parentheses SQL Server adds are removed")
    func stripsWrapper() {
        #expect(MSSQLCheckConstraintDefinition.expression(fromDefinition: "([a]>(0))") == "[a]>(0)")
    }

    @Test("an expression whose parentheses do not wrap the whole thing is left alone")
    func leavesNonEnclosingAlone() {
        let definition = "([a]>(0) AND len([b])<(10))"
        #expect(
            MSSQLCheckConstraintDefinition.expression(fromDefinition: definition)
                == "[a]>(0) AND len([b])<(10)"
        )
    }
}
