//
//  CheckConstraintParsingTests.swift
//  TableProTests
//
//  Every expectation here is a measured server response, not a guess: PostgreSQL 17.11,
//  MariaDB 12.3.2 and SQLite 3.53.4/3.54.0 were probed directly.
//

import Foundation
import Testing

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

struct MySQLServerVersionTests {
    @Test("MariaDB 10.1 has generated columns but no GENERATION_EXPRESSION column")
    func generationExpressionFloor() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "10.1.48-MariaDB", flavor: .mariadb))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "10.2.0-MariaDB", flavor: .mariadb))
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "5.7.5", flavor: .mysql))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "5.7.6", flavor: .mysql))
    }

    @Test("an unreadable banner is treated as unsupported rather than assumed modern")
    func unknownBannerIsUnsupported() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: nil, flavor: .mysql))
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: "unknown", flavor: .mysql))
    }

    /// The other direction: a gate that picks legacy syntax has to hear a version before it does,
    /// because the legacy statements are a 1064 on MySQL 8.
    @Test("isKnownBelow answers false for a banner it cannot read")
    func isKnownBelowNeedsAVersion() {
        #expect(MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "5.6.51"))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "8.4.11"))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: nil))
        #expect(!MySQLServerVersion.isKnownBelow((5, 7, 6), banner: "unknown"))
    }
}

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
