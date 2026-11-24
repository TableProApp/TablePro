import Foundation
import TableProDuckDBCore
import Testing

@Test func aStoredCreateViewRunsAgainAsCreateOrReplace() {
    #expect(DuckDBViewDefinition.makeReplaceable("CREATE VIEW v AS SELECT 1;") == "CREATE OR REPLACE VIEW v AS SELECT 1;")
}

@Test func theLeadingKeywordsMatchInAnyCaseAndSurroundingSpaceIsTrimmed() {
    #expect(DuckDBViewDefinition.makeReplaceable("  create view v AS SELECT 1\n") == "CREATE OR REPLACE VIEW v AS SELECT 1")
}

@Test func aDefinitionThatIsNotAPlainCreateViewComesBackUntouched() {
    let replaceable = "CREATE OR REPLACE VIEW v AS SELECT 1"
    #expect(DuckDBViewDefinition.makeReplaceable(replaceable) == replaceable)
    #expect(DuckDBViewDefinition.makeReplaceable("SELECT 1") == "SELECT 1")
    #expect(DuckDBViewDefinition.makeReplaceable("") == "")
}
