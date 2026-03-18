//
//  SQLDialectDescriptorTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLDialectDescriptorTests: XCTestCase {
    // MARK: - SQLDialectDescriptor Creation

    func testDescriptorCreation() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM", "WHERE"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "VARCHAR"]
        )

        XCTAssertEqual(descriptor.identifierQuote, "`")
        XCTAssertEqual(descriptor.keywords, ["SELECT", "FROM", "WHERE"])
        XCTAssertEqual(descriptor.functions, ["COUNT", "SUM"])
        XCTAssertEqual(descriptor.dataTypes, ["INT", "VARCHAR"])
    }

    func testDescriptorWithEmptySets() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: []
        )

        XCTAssertEqual(descriptor.identifierQuote, "\"")
        XCTAssertTrue(descriptor.keywords.isEmpty)
        XCTAssertTrue(descriptor.functions.isEmpty)
        XCTAssertTrue(descriptor.dataTypes.isEmpty)
    }

    // MARK: - PluginDialectAdapter

    @MainActor
    func testPluginDialectAdapterWrapsDescriptor() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: ["SELECT", "TOP", "NOLOCK"],
            functions: ["LEN", "GETDATE"],
            dataTypes: ["NVARCHAR", "BIT"]
        )

        let adapter = PluginDialectAdapter(descriptor: descriptor)

        XCTAssertEqual(adapter.identifierQuote, "[")
        XCTAssertEqual(adapter.keywords, ["SELECT", "TOP", "NOLOCK"])
        XCTAssertEqual(adapter.functions, ["LEN", "GETDATE"])
        XCTAssertEqual(adapter.dataTypes, ["NVARCHAR", "BIT"])
    }

    @MainActor
    func testPluginDialectAdapterConformsToSQLDialectProvider() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "TEXT"]
        )

        let adapter: SQLDialectProvider = PluginDialectAdapter(descriptor: descriptor)

        XCTAssertTrue(adapter.isKeyword("SELECT"))
        XCTAssertTrue(adapter.isKeyword("select"))
        XCTAssertFalse(adapter.isKeyword("NONEXISTENT"))

        XCTAssertTrue(adapter.isFunction("COUNT"))
        XCTAssertTrue(adapter.isFunction("count"))
        XCTAssertFalse(adapter.isFunction("NONEXISTENT"))

        XCTAssertTrue(adapter.isDataType("INT"))
        XCTAssertTrue(adapter.isDataType("int"))
        XCTAssertFalse(adapter.isDataType("NONEXISTENT"))
    }
}
