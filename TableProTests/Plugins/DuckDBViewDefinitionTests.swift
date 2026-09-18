//
//  DuckDBViewDefinitionTests.swift
//  TableProTests
//
//  Tests for DuckDBViewDefinition (compiled via project.yml from DuckDBDriverPlugin).
//  The input below is what libduckdb 1.5.2 stores and returns for a view.
//

import Foundation
import Testing

@Suite("DuckDB view definition")
struct DuckDBViewDefinitionTests {
    @Test("A stored CREATE VIEW is promoted so it can be run again")
    func createViewBecomesReplaceable() {
        let stored = "CREATE VIEW v_child AS SELECT cid, pid FROM child;"
        #expect(
            DuckDBViewDefinition.makeReplaceable(stored)
                == "CREATE OR REPLACE VIEW v_child AS SELECT cid, pid FROM child;"
        )
    }

    @Test("A definition that already replaces is left alone")
    func alreadyReplaceableIsUntouched() {
        let stored = "CREATE OR REPLACE VIEW v AS SELECT 1;"
        #expect(DuckDBViewDefinition.makeReplaceable(stored) == stored)
    }

    @Test("The keyword match ignores case")
    func keywordMatchIgnoresCase() {
        #expect(
            DuckDBViewDefinition.makeReplaceable("create view v AS SELECT 1;")
                == "CREATE OR REPLACE VIEW v AS SELECT 1;"
        )
    }

    @Test("Leading whitespace is trimmed rather than defeating the match")
    func leadingWhitespaceIsTrimmed() {
        #expect(
            DuckDBViewDefinition.makeReplaceable("\n  CREATE VIEW v AS SELECT 1;")
                == "CREATE OR REPLACE VIEW v AS SELECT 1;"
        )
    }

    /// Anything that is not a plain CREATE VIEW is returned untouched rather than rewritten
    /// on a guess.
    @Test("Something other than a CREATE VIEW is returned unchanged")
    func otherStatementsAreUnchanged() {
        #expect(DuckDBViewDefinition.makeReplaceable("SELECT 1;") == "SELECT 1;")
        #expect(DuckDBViewDefinition.makeReplaceable("CREATE TEMP VIEW v AS SELECT 1;")
            == "CREATE TEMP VIEW v AS SELECT 1;")
        #expect(DuckDBViewDefinition.makeReplaceable("") == "")
        #expect(DuckDBViewDefinition.makeReplaceable("CREATE") == "CREATE")
    }

    /// A view whose name starts with the keyword must not be mangled.
    @Test("Only the leading keyword is rewritten")
    func onlyTheLeadingKeywordIsRewritten() {
        let stored = "CREATE VIEW v AS SELECT 'CREATE VIEW' AS label;"
        #expect(
            DuckDBViewDefinition.makeReplaceable(stored)
                == "CREATE OR REPLACE VIEW v AS SELECT 'CREATE VIEW' AS label;"
        )
    }
}
