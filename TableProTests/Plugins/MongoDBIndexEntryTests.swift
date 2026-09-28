//
//  MongoDBIndexEntryTests.swift
//  TableProTests
//
//  Fixtures are listIndexes documents as libmongoc 1.28 renders them in canonical Extended JSON,
//  read from MongoDB 7.0.43.
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBIndexEntryTests {
    private func entry(_ json: String) throws -> MongoDBIndexEntry {
        try #require(MongoDBIndexEntry(json: json))
    }

    private func int(_ value: Int) -> String {
        "{ \"$numberInt\" : \"\(value)\" }"
    }

    @Test("A compound key keeps the order the server sent, in the columns and in the statement")
    func compoundKeyKeepsServerOrder() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "zeta" : \(int(1)), "alpha" : \(int(1)), "mid" : \(int(-1)), \
            "beta" : \(int(1)), "omega" : \(int(-1)), "delta" : \(int(1)) }, \
            "name" : "zeta_1_alpha_1_mid_-1_beta_1_omega_-1_delta_1", "unique" : true, "sparse" : true }
            """)

        #expect(index.columns == ["zeta", "alpha", "mid", "beta", "omega", "delta"])
        #expect(index.isUnique)
        #expect(index.kind == .btree)
        #expect(index.createIndexStatement(collection: "people") == """
            db.people.createIndex({ "zeta" : 1, "alpha" : 1, "mid" : -1, "beta" : 1, "omega" : -1, "delta" : 1 }, \
            { "name" : "zeta_1_alpha_1_mid_-1_beta_1_omega_-1_delta_1", "unique" : true, "sparse" : true })
            """)
    }

    @Test("A descending field keeps its direction")
    func directionSurvives() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "lastName" : \(int(1)), "firstName" : \(int(-1)) }, \
            "name" : "lastName_1_firstName_-1" }
            """)

        #expect(index.columns == ["lastName", "firstName"])
        #expect(index.createIndexStatement(collection: "people").contains("\"firstName\" : -1"))
        #expect(!index.isUnique)
    }

    @Test("A TTL index keeps its expiry")
    func ttlOptionIsKept() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "ts" : \(int(1)) }, "name" : "ts_1", "expireAfterSeconds" : \(int(3_600)) }
            """)

        #expect(index.createIndexStatement(collection: "people")
            == "db.people.createIndex({ \"ts\" : 1 }, { \"name\" : \"ts_1\", \"expireAfterSeconds\" : 3600 })")
    }

    @Test("A partial filter keeps its member order and the collation loses only its ICU version")
    func partialFilterAndCollationAreKept() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "age" : \(int(1)) }, "name" : "age_1", \
            "partialFilterExpression" : { "b" : { "$gt" : \(int(1)) }, "age" : { "$exists" : true } }, \
            "collation" : { "locale" : "fr", "caseLevel" : false, "strength" : \(int(2)), "version" : "57.1" } }
            """)

        #expect(index.createIndexStatement(collection: "people") == """
            db.people.createIndex({ "age" : 1 }, { "name" : "age_1", \
            "partialFilterExpression" : { "b" : { "$gt" : 1 }, "age" : { "$exists" : true } }, \
            "collation" : { "locale" : "fr", "caseLevel" : false, "strength" : 2 } })
            """)
    }

    @Test("An Int64 and a whole Double in a key or a partial filter keep their types in the statement")
    func typedValuesKeepTheirTypes() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "w" : { "$numberDouble" : "1.0" } }, "name" : "typed", \
            "partialFilterExpression" : { "big" : { "$gt" : { "$numberLong" : "9007199254740993" } }, \
            "w" : { "$gte" : { "$numberDouble" : "1.0" } }, "a" : { "$gt" : { "$numberLong" : "2" } }, \
            "f" : { "$lt" : { "$numberDouble" : "2.5" } } }, "expireAfterSeconds" : { "$numberLong" : "3600" } }
            """)

        #expect(index.createIndexStatement(collection: "src") == """
            db.src.createIndex({ "w" : Double(1.0) }, { "name" : "typed", \
            "partialFilterExpression" : { "big" : { "$gt" : NumberLong("9007199254740993") }, \
            "w" : { "$gte" : Double(1.0) }, "a" : { "$gt" : NumberLong("2") }, "f" : { "$lt" : 2.5 } }, \
            "expireAfterSeconds" : NumberLong("3600") })
            """)
    }

    @Test("The catalog's own members never reach createIndex")
    func versionAndNamespaceAreDropped() throws {
        let index = try entry("""
            { "v" : \(int(1)), "key" : { "a" : \(int(1)) }, "name" : "a_1", "ns" : "shop.orders", "sparse" : true }
            """)

        #expect(index.options.map(\.key) == ["name", "sparse"])
    }

    @Test("A text index lists its weighted fields where _fts stands, between its other key fields")
    func textIndexListsWeightedFields() throws {
        let index = try entry("""
            { "v" : \(int(2)), "key" : { "a" : \(int(1)), "_fts" : "text", "_ftsx" : \(int(1)), "z" : \(int(-1)) }, \
            "name" : "a_1_alpha_text_zeta_text_z_-1", "weights" : { "alpha" : \(int(1)), "zeta" : \(int(1)) }, \
            "default_language" : "english", "language_override" : "language", "textIndexVersion" : \(int(3)) }
            """)

        #expect(index.columns == ["a", "alpha", "zeta", "z"])
        #expect(index.kind == .text)
        #expect(index.pluginIndexInfo.type == "FULLTEXT")
        let statement = index.createIndexStatement(collection: "notes")
        for option in ["\"weights\" : { \"alpha\" : 1, \"zeta\" : 1 }", "\"default_language\" : \"english\"",
                       "\"language_override\" : \"language\"", "\"textIndexVersion\" : 3"] {
            #expect(statement.contains(option))
        }
    }

    @Test("The key decides the index type, and every option of that type is kept")
    func kindFromKey() throws {
        let cases: [(json: String, type: String, option: String?)] = [
            ("{ \"v\" : \(int(2)), \"key\" : { \"h\" : \"hashed\" }, \"name\" : \"h_hashed\" }", "HASH", nil),
            (
                """
                { "v" : \(int(2)), "key" : { "loc" : "2dsphere" }, "name" : "loc_2dsphere", \
                "2dsphereIndexVersion" : \(int(3)) }
                """,
                "SPATIAL", "\"2dsphereIndexVersion\" : 3"
            ),
            (
                """
                { "v" : \(int(2)), "key" : { "p" : "2d" }, "name" : "p_2d", "bits" : \(int(20)), \
                "min" : { "$numberDouble" : "-500.0" }, "max" : { "$numberDouble" : "500.0" } }
                """,
                "2D", "\"bits\" : 20, \"min\" : Double(-500.0), \"max\" : Double(500.0)"
            ),
            (
                """
                { "v" : \(int(2)), "key" : { "$**" : \(int(1)) }, "name" : "$**_1", \
                "wildcardProjection" : { "alpha" : \(int(1)), "zeta" : \(int(1)) } }
                """,
                "WILDCARD", "\"wildcardProjection\" : { \"alpha\" : 1, \"zeta\" : 1 }"
            ),
            ("{ \"v\" : \(int(2)), \"key\" : { \"tags.$**\" : \(int(1)) }, \"name\" : \"tags.$**_1\" }", "WILDCARD", nil),
            (
                "{ \"v\" : \(int(2)), \"key\" : { \"omega\" : \(int(1)) }, \"name\" : \"omega_1\", \"hidden\" : true }",
                "BTREE", "\"hidden\" : true"
            ),
            (
                "{ \"v\" : \(int(2)), \"key\" : { \"a\" : \(int(1)), \"loc\" : \"2dsphere\" }, \"name\" : \"a_1_loc_2dsphere\" }",
                "SPATIAL", nil
            )
        ]

        for testCase in cases {
            let index = try entry(testCase.json)
            #expect(index.pluginIndexInfo.type == testCase.type, "\(testCase.json)")
            if let option = testCase.option {
                #expect(index.createIndexStatement(collection: "c").contains(option), "\(testCase.json)")
            }
        }
    }

    @Test("The four types the structure editor writes read back as the names it wrote them under")
    func kindNamesMatchTheStructureEditor() {
        let spellings: [(value: String, type: String)] = [
            (int(1), "BTREE"), ("\"hashed\"", "HASH"), ("\"text\"", "FULLTEXT"), ("\"2dsphere\"", "SPATIAL")
        ]
        for spelling in spellings {
            #expect(MongoDBIndexKind(keyFields: [(name: "a", value: spelling.value)]).pluginTypeName == spelling.type)
        }
    }

    @Test("_id_ is the primary key and unique without saying so")
    func idIndexIsPrimaryAndUnique() throws {
        let index = try entry("{ \"v\" : \(int(2)), \"key\" : { \"_id\" : \(int(1)) }, \"name\" : \"_id_\" }")

        #expect(index.isPrimary)
        #expect(index.isUnique)
        #expect(index.pluginIndexInfo.columns == ["_id"])
    }

    @Test("A field name holding a quote and a backslash comes back decoded and goes out escaped")
    func fieldNameWithQuoteRoundTrips() throws {
        let index = try entry("{ \"v\" : \(int(2)), \"key\" : { \"a\\\"b\\\\c\" : \(int(1)) }, \"name\" : \"a\\\"b\\\\c_1\" }")

        #expect(index.columns == ["a\"b\\c"])
        #expect(index.name == "a\"b\\c_1")
        #expect(index.createIndexStatement(collection: "c").hasSuffix("{ \"name\" : \"a\\\"b\\\\c_1\" })"))
    }

    @Test("A collection whose name the shell would read as a method is reached through getCollection")
    func shadowedCollectionName() throws {
        let index = try entry("{ \"v\" : \(int(2)), \"key\" : { \"a\" : \(int(1)) }, \"name\" : \"a_1\" }")

        #expect(index.createIndexStatement(collection: "stats").hasPrefix("db.getCollection(\"stats\").createIndex("))
    }

    @Test("A document with no key or no name is not an index")
    func incompleteDocumentsAreSkipped() {
        #expect(MongoDBIndexEntry(json: "{ \"v\" : \(int(2)), \"name\" : \"a_1\" }") == nil)
        #expect(MongoDBIndexEntry(json: "{ \"v\" : \(int(2)), \"key\" : { \"a\" : \(int(1)) } }") == nil)
    }
}
