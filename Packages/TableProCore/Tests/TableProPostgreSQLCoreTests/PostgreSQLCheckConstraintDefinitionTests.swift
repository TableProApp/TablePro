// Every expectation here is a measured PostgreSQL 17.11 response, not a guess.

import Foundation
import Testing

@testable import TableProPostgreSQLCore

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
