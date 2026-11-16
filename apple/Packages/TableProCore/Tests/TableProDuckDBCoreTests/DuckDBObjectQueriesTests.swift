import Foundation
import TableProDuckDBCore
import Testing

@Test func aScalarMacroDropsWithDropMacro() {
    #expect(DuckDBObjectQueries.dropMacro(name: "add_one", schema: "main", isTableMacro: false)
        == #"DROP MACRO IF EXISTS "main"."add_one""#)
}

@Test func aTableMacroDropsWithDropMacroTable() {
    #expect(DuckDBObjectQueries.dropMacro(name: "rows_of", schema: "main", isTableMacro: true)
        == #"DROP MACRO TABLE IF EXISTS "main"."rows_of""#)
}

@Test func aMacroWithNoSchemaDropsByItsBareName() {
    #expect(DuckDBObjectQueries.dropMacro(name: "m", schema: nil, isTableMacro: false) == #"DROP MACRO IF EXISTS "m""#)
    #expect(DuckDBObjectQueries.dropMacro(name: "m", schema: "", isTableMacro: false) == #"DROP MACRO IF EXISTS "m""#)
}

@Test func aQuoteInAMacroNameStaysInsideTheIdentifier() {
    #expect(DuckDBObjectQueries.qualifiedName(schema: #"s"x"#, name: #"a"b"#) == #""s""x"."a""b""#)
}

@Test func theMacroListNamesTheCatalogAndTheSchemaAsLiterals() {
    let sql = DuckDBObjectQueries.macroList(catalog: "it's", schema: "main")
    #expect(sql.contains("WHERE database_name = 'it''s' AND schema_name = 'main'"))
    #expect(sql.contains("function_type IN ('macro', 'table_macro') AND NOT internal"))
}

@Test func theMacroListWithNoSchemaReadsEverySchemaOfTheCatalog() {
    let sql = DuckDBObjectQueries.macroList(catalog: "memory", schema: nil)
    #expect(sql.contains("WHERE database_name = 'memory'\n"))
    #expect(!sql.contains("schema_name = "))
}

@Test func aTableMacroSignatureNamesItsKind() {
    #expect(DuckDBObjectQueries.macroSignature(parameterNames: ["a", "b"], isTableMacro: true) == "(a, b) AS TABLE")
    #expect(DuckDBObjectQueries.macroSignature(parameterNames: ["a", "b"], isTableMacro: false) == "(a, b)")
    #expect(DuckDBObjectQueries.macroSignature(parameterNames: [], isTableMacro: false) == "()")
}

@Test func aScalarAndATableMacroOfOneNameAndParametersGetTwoSignatures() {
    #expect(DuckDBObjectQueries.macroSignature(parameterNames: ["a"], isTableMacro: true)
        != DuckDBObjectQueries.macroSignature(parameterNames: ["a"], isTableMacro: false))
}

@Test func aTableMacroSignatureDropsWithDropMacroTable() {
    let signature = DuckDBObjectQueries.macroSignature(parameterNames: ["a"], isTableMacro: true)
    #expect(DuckDBObjectQueries.namesTableMacro(signature))
    #expect(DuckDBObjectQueries.dropMacro(
        name: "rows_of", schema: "main", isTableMacro: DuckDBObjectQueries.namesTableMacro(signature)
    ) == #"DROP MACRO TABLE IF EXISTS "main"."rows_of""#)
}

@Test(arguments: ["(a)", "()", "(x) AS TABLE)", nil] as [String?])
func aScalarMacroSignatureDropsWithDropMacro(signature: String?) {
    #expect(!DuckDBObjectQueries.namesTableMacro(signature))
}
