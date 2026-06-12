//
//  PostgreSQLSearchPathTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostgreSQLSchemaQueries.setSearchPath")
struct PostgreSQLSearchPathTests {
    @Test("quotes the schema as an identifier")
    func plainSchema() {
        #expect(
            PostgreSQLSchemaQueries.setSearchPath(toSchema: "analytics")
                == "SET search_path TO \"analytics\""
        )
    }

    @Test("sets public as the only search path entry when selected")
    func publicSchema() {
        #expect(
            PostgreSQLSchemaQueries.setSearchPath(toSchema: "public")
                == "SET search_path TO \"public\""
        )
    }

    @Test("preserves mixed-case schema names with identifier quoting")
    func mixedCaseSchema() {
        #expect(
            PostgreSQLSchemaQueries.setSearchPath(toSchema: "MySchema")
                == "SET search_path TO \"MySchema\""
        )
    }

    @Test("doubles embedded double quotes so the name stays a single identifier")
    func schemaWithEmbeddedQuote() {
        #expect(
            PostgreSQLSchemaQueries.setSearchPath(toSchema: "wei\"rd")
                == "SET search_path TO \"wei\"\"rd\""
        )
    }

    @Test("neutralizes a quote-break injection attempt")
    func injectionAttempt() {
        let malicious = "public\"; DROP TABLE users; --"
        #expect(
            PostgreSQLSchemaQueries.setSearchPath(toSchema: malicious)
                == "SET search_path TO \"public\"\"; DROP TABLE users; --\""
        )
    }
}
