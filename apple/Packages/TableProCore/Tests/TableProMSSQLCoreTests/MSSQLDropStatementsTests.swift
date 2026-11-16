import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLDropStatementsTests {
    @Test("A function drops with DROP FUNCTION, qualified by its schema")
    func functionDrop() {
        let signature = MSSQLRoutineSignature.listed(parameters: "@id int", objectType: "FN")
        #expect(MSSQLDropStatements.routine(schema: "dbo", name: "fn_total", isFunction: true, signature: signature)
            == "DROP FUNCTION IF EXISTS [dbo].[fn_total]")
    }

    @Test("A procedure drops with DROP PROCEDURE, never DROP ROUTINE")
    func procedureDrop() {
        let statement = MSSQLDropStatements.routine(schema: "sales", name: "usp_close", isFunction: false, signature: "()")
        #expect(statement == "DROP PROCEDURE IF EXISTS [sales].[usp_close]")
        #expect(!statement.contains("ROUTINE"))
    }

    @Test("A closing bracket in a routine or schema name is doubled")
    func bracketInNameIsEscaped() {
        #expect(MSSQLDropStatements.routine(schema: "a]b", name: "p]q", isFunction: false, signature: nil)
            == "DROP PROCEDURE IF EXISTS [a]]b].[p]]q]")
    }

    @Test("A CLR aggregate listed as a function drops with DROP AGGREGATE", arguments: ["AF", "af", "AF "])
    func aggregateDrop(objectType: String) {
        let signature = MSSQLRoutineSignature.listed(parameters: "@value nvarchar", objectType: objectType)
        #expect(MSSQLDropStatements.routine(schema: "dbo", name: "Concatenate", isFunction: true, signature: signature)
            == "DROP AGGREGATE IF EXISTS [dbo].[Concatenate]")
    }

    @Test("A CLR scalar or table-valued function still drops with DROP FUNCTION", arguments: ["FS", "FT", "IF", "TF"])
    func clrFunctionDrop(objectType: String) {
        let signature = MSSQLRoutineSignature.listed(parameters: "", objectType: objectType)
        #expect(MSSQLDropStatements.routine(schema: "dbo", name: "f", isFunction: true, signature: signature)
            == "DROP FUNCTION IF EXISTS [dbo].[f]")
    }

    @Test("A parameter named like the marker leaves a function a function")
    func parameterNamedAggregate() {
        let signature = MSSQLRoutineSignature.listed(parameters: "@x AGGREGATE", objectType: "FN")
        #expect(signature == "(@x AGGREGATE)")
        #expect(!MSSQLRoutineSignature.namesAggregate(signature))
    }

    @Test("An aggregate's signature keeps its parameter list")
    func aggregateSignature() {
        #expect(MSSQLRoutineSignature.listed(parameters: "@value nvarchar", objectType: "AF")
            == "(@value nvarchar) AGGREGATE")
        #expect(MSSQLRoutineSignature.listed(parameters: "@id int", objectType: "FN") == "(@id int)")
    }

    @Test("A trigger drops by its schema and name, without its table")
    func triggerDrop() {
        #expect(MSSQLDropStatements.trigger(schema: "dbo", name: "trg_audit") == "DROP TRIGGER [dbo].[trg_audit]")
    }
}
