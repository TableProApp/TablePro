//
//  PostgreSQLExtensionQueryTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLExtensionQueryTests {
    private func row(_ cells: String?...) -> [PluginCellValue] {
        cells.map(PluginCellValue.fromOptional)
    }

    private func attribute(_ object: PluginServerObjectInfo?, _ label: String) -> String? {
        object?.attributes.first { $0.label == label }?.value
    }

    private static let constructsMissingBefore91 = [
        "to_regclass", "LATERAL", "WITH ORDINALITY", "json", "array_remove", "array_position", "FILTER (", "unnest("
    ]

    @Test("The extension reads stay inside what PostgreSQL 9.1 parses")
    func readsArePortable() {
        let queries = [
            PostgreSQLExtensionQueries.list,
            PostgreSQLExtensionQueries.one(oid: 16_384),
            PostgreSQLExtensionQueries.defaultVersion(name: "pgcrypto")
        ]
        for sql in queries {
            #expect(Self.constructsMissingBefore91.filter { sql.contains($0) }.isEmpty, "\(sql)")
        }
    }

    @Test("The listing reads every extension once, by name, without the control files")
    func listingIsOneCatalogRead() {
        let sql = PostgreSQLExtensionQueries.list
        #expect(sql.contains("FROM pg_catalog.pg_extension e"))
        #expect(sql.contains("JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace"))
        #expect(sql.hasSuffix("ORDER BY e.extname"))
        #expect(!sql.contains("pg_available_extensions"))
        #expect(!sql.contains("WHERE"))
    }

    @Test("One extension is read again by its oid alone")
    func rereadIsByOid() {
        let sql = PostgreSQLExtensionQueries.one(oid: 16_384)
        #expect(sql.hasSuffix("WHERE e.oid = 16384"))
        #expect(!sql.contains("extname ="))
    }

    @Test("The default version read quotes its name as a literal")
    func defaultVersionQuotesTheName() {
        #expect(PostgreSQLExtensionQueries.defaultVersion(name: "o'brien").contains("WHERE name = 'o''brien'"))
    }

    @Test("A plain extension's definition is pg_dump's, with no version")
    func plainDefinition() {
        #expect(PostgreSQLExtensionQueries.definition(name: "pgcrypto", schema: "public", comment: nil)
            == #"CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "public";"#)
    }

    @Test("A name or schema that needs quoting is quoted as an identifier")
    func quotedDefinition() {
        #expect(PostgreSQLExtensionQueries.definition(name: "uuid-ossp", schema: "My Schema", comment: "")
            == #"CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "My Schema";"#)
    }

    @Test("A comment follows as COMMENT ON EXTENSION, its quote doubled")
    func commentWithAQuote() {
        let text = PostgreSQLExtensionQueries.definition(name: "hstore", schema: "public", comment: "data type for key/value's")
        #expect(text.hasPrefix(#"CREATE EXTENSION IF NOT EXISTS "hstore" WITH SCHEMA "public";"#))
        #expect(text.hasSuffix(#"COMMENT ON EXTENSION "hstore" IS 'data type for key/value''s';"#))
    }

    @Test("A listed row carries its oid, version and definition")
    func rowMapping() {
        let object = PostgreSQLExtensionQueries.object(
            from: row("16384", "pgcrypto", "public", "1.3", "true", "postgres", "cryptographic functions")
        )

        #expect(object?.kindId == "extension")
        #expect(object?.identity == "16384")
        #expect(object?.name == "pgcrypto")
        #expect(object?.schema == "public")
        #expect(object?.detail == "1.3")
        #expect(object?.isEnabled == nil)
        #expect(attribute(object, String(localized: "Version")) == "1.3")
        #expect(attribute(object, String(localized: "Owner")) == "postgres")
        #expect(attribute(object, String(localized: "Relocatable")) == String(localized: "Yes"))
        #expect(attribute(object, String(localized: "Default Version")) == nil)
        #expect(object?.definition?.contains("COMMENT ON EXTENSION \"pgcrypto\"") == true)
    }

    @Test("The re-read adds the default version, and a non-relocatable extension says No")
    func rereadRowMapping() {
        let object = PostgreSQLExtensionQueries.object(
            from: row("13000", "plpgsql", "pg_catalog", "1.0", "f", "postgres", nil),
            defaultVersion: "1.0"
        )

        #expect(attribute(object, String(localized: "Default Version")) == "1.0")
        #expect(attribute(object, String(localized: "Relocatable")) == String(localized: "No"))
        #expect(attribute(object, String(localized: "Comment")) == nil)
        #expect(object?.definition == #"CREATE EXTENSION IF NOT EXISTS "plpgsql" WITH SCHEMA "pg_catalog";"#)
    }

    @Test("A row without an oid is not an extension this driver can read again")
    func rowWithoutOidIsDropped() {
        #expect(PostgreSQLExtensionQueries.object(from: row(nil, "pgcrypto", "public", "1.3", "t", nil, nil)) == nil)
        #expect(PostgreSQLExtensionQueries.object(from: row("pgcrypto", "pgcrypto", "public", "1.3", "t", nil, nil)) == nil)
    }

    @Test("Extensions are declared from 9.1, at database scope")
    func declaredFromNinePointOne() {
        #expect(!PostgreSQLExtensions.isDeclared(capabilities: PostgreSQLCapabilities(serverVersion: 90_024)))
        #expect(PostgreSQLExtensions.isDeclared(capabilities: PostgreSQLCapabilities(serverVersion: 90_100)))
        #expect(PostgreSQLExtensions.isDeclared(capabilities: .assumingModernWhenUnknown(0)))
        #expect(PostgreSQLExtensions.kind.scope == .database)
        #expect(PostgreSQLExtensions.kind.id == "extension")
    }
}
