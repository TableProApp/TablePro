//
//  MongoDBNamespaceEntryTests.swift
//  TableProTests
//
//  Fixtures are listCollections entries as libmongoc 1.28 renders them in canonical Extended JSON,
//  read from MongoDB 7.0.43.
//

import Foundation
import Testing

@testable import TablePro

struct MongoDBNamespaceEntryTests {
    private static let adults = """
        { "name" : "adults", "type" : "view", "options" : { "viewOn" : "people", "pipeline" : \
        [ { "$match" : { "age" : { "$gte" : { "$numberInt" : "4" } } } }, \
        { "$sort" : { "lastName" : { "$numberInt" : "1" }, "firstName" : { "$numberInt" : "-1" } } } ], \
        "collation" : { "locale" : "en", "strength" : { "$numberInt" : "2" }, "version" : "57.1" } }, \
        "info" : { "readOnly" : true } }
        """

    private static let plainView = """
        { "name" : "plainview", "type" : "view", "options" : { "viewOn" : "people", "pipeline" : \
        [ { "$project" : { "lastName" : { "$numberInt" : "1" } } } ] }, "info" : { "readOnly" : true } }
        """

    private static let typedView = """
        { "name" : "typed", "type" : "view", "options" : { "viewOn" : "src", "pipeline" : \
        [ { "$match" : { "a" : { "$gte" : { "$numberLong" : "1" } }, "w" : { "$eq" : { "$numberDouble" : "1.0" } }, \
        "big" : { "$eq" : { "$numberLong" : "9007199254740993" } }, "i" : { "$numberInt" : "7" }, \
        "neg0" : { "$numberDouble" : "-0.0" }, "when" : { "$date" : { "$numberLong" : "1577934245678" } }, \
        "many" : { "$in" : [ { "$minKey" : 1 }, { "$timestamp" : { "t" : 5, "i" : 6 } } ] } } } ], \
        "collation" : { "locale" : "en", "strength" : { "$numberInt" : "2" }, "version" : "57.1" } }, \
        "info" : { "readOnly" : true } }
        """

    private static let int1 = "{ \"$numberInt\" : \"1\" }"
    private static let int2 = "{ \"$numberInt\" : \"2\" }"

    private func entry(_ json: String) throws -> MongoDBNamespaceEntry {
        try #require(MongoDBNamespaceEntry(json: json))
    }

    private func index(_ json: String) throws -> MongoDBIndexEntry {
        try #require(MongoDBIndexEntry(json: json))
    }

    @Test("Each kind of namespace listCollections reports maps to the table type the app reads")
    func kindMapping() throws {
        let expected: [(json: String, type: String)] = [
            ("{ \"name\" : \"people\", \"type\" : \"collection\" }", "TABLE"),
            ("{ \"name\" : \"adults\", \"type\" : \"view\" }", "VIEW"),
            ("{ \"name\" : \"metrics\", \"type\" : \"timeseries\" }", "TABLE"),
            ("{ \"name\" : \"system.views\", \"type\" : \"collection\" }", "SYSTEM TABLE"),
            ("{ \"name\" : \"system.buckets.metrics\", \"type\" : \"collection\" }", "SYSTEM TABLE"),
            ("{ \"name\" : \"system.profile\", \"type\" : \"collection\" }", "SYSTEM TABLE"),
            ("{ \"name\" : \"legacy\" }", "TABLE"),
            ("{ \"name\" : \"systemx\", \"type\" : \"collection\" }", "TABLE")
        ]

        for namespace in expected {
            #expect(try entry(namespace.json).pluginTableType == namespace.type, "\(namespace.json)")
        }
    }

    @Test("The plugin's spelling decodes to the app's view, table and system table kinds")
    func kindMappingDecodesInTheApp() throws {
        let expected: [(json: String, kind: TableInfo.TableType)] = [
            ("{ \"name\" : \"adults\", \"type\" : \"view\" }", .view),
            ("{ \"name\" : \"people\", \"type\" : \"collection\" }", .table),
            ("{ \"name\" : \"metrics\", \"type\" : \"timeseries\" }", .table),
            ("{ \"name\" : \"system.views\", \"type\" : \"collection\" }", .systemTable)
        ]

        for namespace in expected {
            let decoded = PluginTableKindDecoder.decode(try entry(namespace.json).pluginTableType)
            #expect(decoded.kind == namespace.kind, "\(namespace.json)")
            #expect(!decoded.isSystemVersioned)
        }
    }

    @Test("A view's statement keeps its pipeline's stage and $sort order, and its collation without the ICU version")
    func createViewKeepsPipelineOrderAndCollation() throws {
        #expect(try entry(Self.adults).createViewStatement() == """
            db.createView("adults", "people", [
              {
                "$match": {
                  "age": {
                    "$gte": 4
                  }
                }
              },
              {
                "$sort": {
                  "lastName": 1,
                  "firstName": -1
                }
              }
            ], {
              "collation": {
                "locale": "en",
                "strength": 2
              }
            })
            """)
    }

    @Test("A view with no collation is created with three arguments")
    func createViewWithoutCollationHasThreeArguments() throws {
        #expect(try entry(Self.plainView).createViewStatement() == """
            db.createView("plainview", "people", [
              {
                "$project": {
                  "lastName": 1
                }
              }
            ])
            """)
    }

    @Test("The collMod that redefines a view leaves its collation out, which collMod refuses")
    func collModOmitsCollation() throws {
        #expect(try entry(Self.adults).collModStatement() == """
            db.runCommand({
              "collMod": "adults",
              "viewOn": "people",
              "pipeline": [
                {
                  "$match": {
                    "age": {
                      "$gte": 4
                    }
                  }
                },
                {
                  "$sort": {
                    "lastName": 1,
                    "firstName": -1
                  }
                }
              ]
            })
            """)
    }

    @Test("A view's Int64, whole Double, date and bounds are written through the constructors that keep their types")
    func viewStatementsKeepValueTypes() throws {
        let view = try entry(Self.typedView)
        let match = """
                "$match": {
                  "a": {
                    "$gte": NumberLong("1")
                  },
                  "w": {
                    "$eq": Double(1.0)
                  },
                  "big": {
                    "$eq": NumberLong("9007199254740993")
                  },
                  "i": 7,
                  "neg0": Double(-0.0),
                  "when": ISODate("2020-01-02T03:04:05.678Z"),
                  "many": {
                    "$in": [
                      MinKey(),
                      Timestamp(5, 6)
                    ]
                  }
                }
            """

        #expect(view.createViewStatement() == """
            db.createView("typed", "src", [
              {
            \(match)
              }
            ], {
              "collation": {
                "locale": "en",
                "strength": 2
              }
            })
            """)
        #expect(try #require(view.collModStatement()).contains("\"$eq\": NumberLong(\"9007199254740993\")"))
        #expect(try #require(view.collModStatement()).contains("\"$eq\": Double(1.0)"))
    }

    @Test("A collection has no view statements")
    func nonViewHasNoViewStatements() throws {
        let collection = try entry("{ \"name\" : \"people\", \"type\" : \"collection\", \"options\" : { } }")

        #expect(collection.createViewStatement() == nil)
        #expect(collection.collModStatement() == nil)
    }

    @Test("A view's DDL has its own header, so MQL export never appends it to exported documents")
    func viewDDLHasViewHeaderAndNoIndexes() throws {
        let text = MongoDBNamespaceDDL.text(name: "adults", entry: try entry(Self.adults), indexes: [])

        #expect(text.hasPrefix("// View: adults\ndb.createView(\"adults\", \"people\", ["))
        #expect(!text.contains("// Collection:"))
        #expect(!text.contains("// Indexes"))
    }

    @Test("A capped collection's size and max are read from the options")
    func cappedSizeIsRead() throws {
        let capped = try entry("""
            { "name" : "capped1", "type" : "collection", "options" : { "capped" : true, \
            "size" : { "$numberInt" : "4096" }, "max" : { "$numberLong" : "10" } } }
            """)

        #expect(MongoDBNamespaceDDL.text(name: "capped1", entry: capped, indexes: [])
            == "// Collection: capped1\n// Capped: true, size: 4096, max: 10")
    }

    @Test("A validator keeps its properties in declared order and the collection name is escaped")
    func validatorKeepsPropertyOrder() throws {
        let validated = try entry("""
            { "name" : "we\\"ird", "type" : "collection", "options" : { "validator" : { "$jsonSchema" : \
            { "bsonType" : "object", "properties" : { "zeta" : { "bsonType" : "string" }, \
            "alpha" : { "bsonType" : "long", "minimum" : { "$numberLong" : "9007199254740993" } } } } } } }
            """)

        #expect(MongoDBNamespaceDDL.text(name: "we\"ird", entry: validated, indexes: []) == """
            // Collection: we"ird

            // Validator
            db.runCommand({
              "collMod": "we\\"ird",
              "validator": {
                "$jsonSchema": {
                  "bsonType": "object",
                  "properties": {
                    "zeta": {
                      "bsonType": "string"
                    },
                    "alpha": {
                      "bsonType": "long",
                      "minimum": NumberLong("9007199254740993")
                    }
                  }
                }
              }
            })
            """)
    }

    @Test("A time-series collection says so in its DDL")
    func timeSeriesLineIsWritten() throws {
        let metrics = try entry("""
            { "name" : "metrics", "type" : "timeseries", "options" : { "timeseries" : { "timeField" : "ts", \
            "metaField" : "meta", "granularity" : "hours", "bucketMaxSpanSeconds" : { "$numberInt" : "2592000" } } } }
            """)

        #expect(MongoDBNamespaceDDL.text(name: "metrics", entry: metrics, indexes: []) == """
            // Collection: metrics
            // Time series: { "timeField" : "ts", "metaField" : "meta", "granularity" : "hours", \
            "bucketMaxSpanSeconds" : 2592000 }
            """)
    }

    @Test("Indexes are written in listIndexes order and _id_ is left out")
    func ddlSkipsIdIndexAndKeepsListOrder() throws {
        let people = try entry("{ \"name\" : \"people\", \"type\" : \"collection\", \"options\" : { } }")
        let indexes = try [
            index("{ \"v\" : \(Self.int2), \"key\" : { \"_id\" : \(Self.int1) }, \"name\" : \"_id_\" }"),
            index("{ \"v\" : \(Self.int2), \"key\" : { \"zeta\" : \(Self.int1) }, \"name\" : \"zeta_1\" }"),
            index("{ \"v\" : \(Self.int2), \"key\" : { \"alpha\" : \(Self.int1) }, \"name\" : \"alpha_1\" }")
        ]

        #expect(MongoDBNamespaceDDL.text(name: "people", entry: people, indexes: indexes) == """
            // Collection: people

            // Indexes
            db.people.createIndex({ "zeta" : 1 }, { "name" : "zeta_1" })
            db.people.createIndex({ "alpha" : 1 }, { "name" : "alpha_1" })
            """)
    }

    @Test("A namespace whose entry could not be read still gets its header and indexes")
    func nilEntryStillWritesIndexes() throws {
        let indexes = try [index("{ \"v\" : \(Self.int2), \"key\" : { \"a\" : \(Self.int1) }, \"name\" : \"a_1\" }")]

        #expect(MongoDBNamespaceDDL.text(name: "people", entry: nil, indexes: indexes) == """
            // Collection: people

            // Indexes
            db.people.createIndex({ "a" : 1 }, { "name" : "a_1" })
            """)
    }

    @Test("An entry with no name is not a namespace")
    func entryWithoutNameIsSkipped() {
        #expect(MongoDBNamespaceEntry(json: "{ \"type\" : \"collection\" }") == nil)
    }
}
