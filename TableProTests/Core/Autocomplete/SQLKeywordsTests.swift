//
//  SQLKeywordsTests.swift
//  TableProTests
//
//  Tests for SQLKeywords catalog
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL Keywords")
struct SQLKeywordsTests {

    @Test("Keywords collection not empty")
    func testKeywordsNotEmpty() {
        #expect(!SQLKeywords.keywords.isEmpty)
        #expect(SQLKeywords.keywords.count > 50)
    }

    @Test("Keywords contain essential SQL keywords")
    func testKeywordsContainEssentialKeywords() {
        let essentialKeywords = [
            "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN"
        ]

        for keyword in essentialKeywords {
            #expect(SQLKeywords.keywords.contains(keyword),
                   "Missing essential keyword: \(keyword)")
        }
    }

    @Test("All function categories not empty")
    func testFunctionCategoriesNotEmpty() {
        #expect(!SQLKeywords.aggregateFunctions.isEmpty)
        #expect(!SQLKeywords.dateTimeFunctions.isEmpty)
        #expect(!SQLKeywords.stringFunctions.isEmpty)
        #expect(!SQLKeywords.numericFunctions.isEmpty)
        #expect(!SQLKeywords.nullFunctions.isEmpty)
        #expect(!SQLKeywords.conversionFunctions.isEmpty)
        #expect(!SQLKeywords.windowFunctions.isEmpty)
        #expect(!SQLKeywords.jsonFunctions.isEmpty)
    }

    @Test("allFunctions combines all categories")
    func testAllFunctionsCombinesCategories() {
        let expectedCount =
            SQLKeywords.aggregateFunctions.count +
            SQLKeywords.dateTimeFunctions.count +
            SQLKeywords.stringFunctions.count +
            SQLKeywords.numericFunctions.count +
            SQLKeywords.nullFunctions.count +
            SQLKeywords.conversionFunctions.count +
            SQLKeywords.windowFunctions.count +
            SQLKeywords.jsonFunctions.count

        #expect(SQLKeywords.allFunctions.count == expectedCount)
    }

    @Test("keywordItems returns correct count and kind")
    func testKeywordItemsCorrectness() {
        let items = SQLKeywords.keywordItems()

        #expect(items.count == SQLKeywords.keywords.count)

        for item in items {
            #expect(item.kind == .keyword)
        }
    }

    @Test("functionItems returns correct kind")
    func testFunctionItemsCorrectKind() {
        let items = SQLKeywords.functionItems()

        #expect(items.count == SQLKeywords.allFunctions.count)

        for item in items {
            #expect(item.kind == .function)
        }
    }

    @Test("operatorItems returns correct kind")
    func testOperatorItemsCorrectKind() {
        let items = SQLKeywords.operatorItems()

        #expect(items.count == SQLKeywords.operators.count)

        for item in items {
            #expect(item.kind == .operator)
        }
    }

    @Test("No duplicate function names in allFunctions")
    func testNoDuplicateFunctionNames() {
        let functionNames = SQLKeywords.allFunctions.map { $0.name }
        let uniqueNames = Set(functionNames)

        #expect(functionNames.count == uniqueNames.count,
               "Found \(functionNames.count - uniqueNames.count) duplicate function names")
    }

    // MARK: - P2: MP-1 - Missing SQL Keywords

    @Test("Keywords contain window clause keywords")
    func testWindowClauseKeywords() {
        let windowKeywords = ["OVER", "PARTITION", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT ROW"]
        for kw in windowKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing window keyword: \(kw)")
        }
    }

    @Test("Keywords contain PostgreSQL-specific keywords")
    func testPostgreSQLKeywords() {
        let pgKeywords = ["RETURNING", "LATERAL", "CONCURRENTLY", "CONFLICT", "EXCLUDED"]
        for kw in pgKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing PostgreSQL keyword: \(kw)")
        }
    }

    @Test("Keywords contain MySQL-specific keywords")
    func testMySQLKeywords() {
        let mysqlKeywords = ["STRAIGHT_JOIN", "FORCE INDEX", "USE INDEX"]
        for kw in mysqlKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing MySQL keyword: \(kw)")
        }
    }

    @Test("Keywords contain transaction isolation keywords")
    func testTransactionKeywords() {
        let txKeywords = ["ISOLATION", "LEVEL", "READ", "COMMITTED", "REPEATABLE", "SERIALIZABLE"]
        for kw in txKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing transaction keyword: \(kw)")
        }
    }

    @Test("Keywords contain DCL keywords")
    func testDCLKeywords() {
        let dclKeywords = ["GRANT", "REVOKE", "PRIVILEGES", "USAGE"]
        for kw in dclKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing DCL keyword: \(kw)")
        }
    }

    @Test("Keywords contain utility keywords")
    func testUtilityKeywords() {
        let utilKeywords = ["DEALLOCATE", "PREPARE", "EXECUTE"]
        for kw in utilKeywords {
            #expect(SQLKeywords.keywords.contains(kw), "Missing utility keyword: \(kw)")
        }
    }

    // MARK: - P2: MP-2 - Missing Functions

    @Test("Aggregate functions include STDDEV and VARIANCE")
    func testMissingAggregateFunctions() {
        let names = SQLKeywords.aggregateFunctions.map(\.name)
        let expected = ["STDDEV", "VARIANCE", "BIT_AND", "BIT_OR", "JSON_OBJECTAGG", "JSON_ARRAYAGG"]
        for fn in expected {
            #expect(names.contains(fn), "Missing aggregate function: \(fn)")
        }
    }

    @Test("Date/time functions include EXTRACT and DATE_TRUNC")
    func testMissingDateTimeFunctions() {
        let names = SQLKeywords.dateTimeFunctions.map(\.name)
        let expected = ["EXTRACT", "DATE_TRUNC", "AGE", "TO_TIMESTAMP", "LAST_DAY", "MAKEDATE", "MAKETIME"]
        for fn in expected {
            #expect(names.contains(fn), "Missing date/time function: \(fn)")
        }
    }

    @Test("String functions include REGEXP_REPLACE and SPLIT_PART")
    func testMissingStringFunctions() {
        let names = SQLKeywords.stringFunctions.map(\.name)
        let expected = ["REGEXP_REPLACE", "REGEXP_SUBSTR", "SPLIT_PART", "INITCAP", "TRANSLATE"]
        for fn in expected {
            #expect(names.contains(fn), "Missing string function: \(fn)")
        }
    }

    @Test("Numeric functions include trig functions")
    func testMissingNumericFunctions() {
        let names = SQLKeywords.numericFunctions.map(\.name)
        let expected = ["SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "DEGREES", "RADIANS", "PI"]
        for fn in expected {
            #expect(names.contains(fn), "Missing numeric function: \(fn)")
        }
    }

    @Test("JSON functions include PostgreSQL JSON builders")
    func testMissingJSONFunctions() {
        let names = SQLKeywords.jsonFunctions.map(\.name)
        let expected = ["JSON_BUILD_OBJECT", "JSON_BUILD_ARRAY", "JSONB_SET", "JSON_EACH", "ROW_TO_JSON", "JSON_AGG", "JSONB_AGG"]
        for fn in expected {
            #expect(names.contains(fn), "Missing JSON function: \(fn)")
        }
    }

    @Test("allFunctions includes all new functions")
    func testAllFunctionsUpdated() {
        let allNames = SQLKeywords.allFunctions.map(\.name)
        // Spot check a few from different categories
        #expect(allNames.contains("STDDEV"))
        #expect(allNames.contains("EXTRACT"))
        #expect(allNames.contains("REGEXP_REPLACE"))
        #expect(allNames.contains("SIN"))
        #expect(allNames.contains("JSON_BUILD_OBJECT"))
    }
}
