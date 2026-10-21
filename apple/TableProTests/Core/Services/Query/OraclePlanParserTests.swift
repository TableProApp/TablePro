//
//  OraclePlanParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OraclePlanParserTests {
    private let parser = OraclePlanParser()

    private let estimated = """
        [
        {"ID":0,"OPERATION":"SELECT STATEMENT","COST":7,"CARDINALITY":3,"BYTES":153},
        {"ID":1,"PARENT_ID":0,"OPERATION":"HASH JOIN","COST":7,"CARDINALITY":3,"ACCESS_PREDICATES":"\\"O\\".\\"CUSTOMER_ID\\"=\\"C\\".\\"ID\\""},
        {"ID":2,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"BY INDEX ROWID BATCHED","OBJECT_OWNER":"APP","OBJECT_NAME":"CUSTOMERS","OBJECT_TYPE":"TABLE","OBJECT_ALIAS":"C@SEL$1","COST":2,"CARDINALITY":1},
        {"ID":3,"PARENT_ID":2,"OPERATION":"INDEX","OPTIONS":"RANGE SCAN","OBJECT_OWNER":"APP","OBJECT_NAME":"CUSTOMERS_CITY_IX","OBJECT_TYPE":"INDEX","COST":1,"CARDINALITY":1,"ACCESS_PREDICATES":"\\"C\\".\\"CITY\\"='Hanoi'"},
        {"ID":4,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"FULL","OBJECT_OWNER":"APP","OBJECT_NAME":"ORDERS","OBJECT_TYPE":"TABLE","COST":5,"CARDINALITY":40,"FILTER_PREDICATES":"\\"O\\".\\"STATUS\\"='open'"}
        ]
        """

    @Test("ID and PARENT_ID become the tree, in ID order")
    func buildsTreeFromIds() throws {
        let plan = try #require(parser.parse(rawText: estimated))

        #expect(plan.rootNode.operation == "SELECT STATEMENT")
        let join = try #require(plan.rootNode.children.first)
        #expect(join.operation == "HASH JOIN")
        #expect(join.children.map { $0.operation } == ["TABLE ACCESS BY INDEX ROWID BATCHED", "TABLE ACCESS FULL"])
        #expect(join.children[0].children.map { $0.operation } == ["INDEX RANGE SCAN"])
    }

    @Test("Cost, cardinality, object and predicates land where the plan views read them")
    func mapsEstimates() throws {
        let plan = try #require(parser.parse(rawText: estimated))
        let join = try #require(plan.rootNode.children.first)
        let customers = join.children[0]
        let orders = join.children[1]

        #expect(customers.relation == "CUSTOMERS")
        #expect(customers.schema == "APP")
        #expect(customers.alias == "C@SEL$1")
        #expect(customers.estimatedTotalCost == 2)
        #expect(customers.estimatedRows == 1)
        #expect(join.properties["Access Predicates"] == #""O"."CUSTOMER_ID"="C"."ID""#)
        #expect(orders.properties["Filter Predicates"] == #""O"."STATUS"='open'"#)
        #expect(plan.rootNode.properties["Bytes"] == "153")
        #expect(plan.rootNode.actualTotalTime == nil)
        #expect(plan.rootNode.costFraction != nil)
    }

    @Test("An index step names the index rather than calling it a table")
    func indexStepNamesIndex() throws {
        let plan = try #require(parser.parse(rawText: estimated))
        let index = try #require(plan.rootNode.children.first?.children.first?.children.first)

        #expect(index.relation == nil)
        #expect(index.properties["Index Name"] == "CUSTOMERS_CITY_IX")
    }

    @Test("Actual statistics are totals over every start, read back as per-start values")
    func actualStatisticsArePerStart() throws {
        let actual = """
            [
            {"ID":0,"OPERATION":"SELECT STATEMENT"},
            {"ID":1,"PARENT_ID":0,"OPERATION":"NESTED LOOPS","LAST_STARTS":1,"LAST_OUTPUT_ROWS":12,"LAST_ELAPSED_TIME":4000},
            {"ID":2,"PARENT_ID":1,"OPERATION":"INDEX","OPTIONS":"UNIQUE SCAN","OBJECT_NAME":"PK","OBJECT_TYPE":"INDEX (UNIQUE)","LAST_STARTS":4,"LAST_OUTPUT_ROWS":12,"LAST_ELAPSED_TIME":2000,"LAST_CR_BUFFER_GETS":8},
            {"ID":3,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"FULL","OBJECT_NAME":"T","LAST_STARTS":0,"LAST_OUTPUT_ROWS":0}
            ]
            """
        let plan = try #require(parser.parse(rawText: actual))
        let loops = try #require(plan.rootNode.children.first)
        let scan = loops.children[0]

        #expect(scan.actualLoops == 4)
        #expect(scan.actualRows == 3)
        #expect(scan.actualTotalTime == 0.5)
        #expect(scan.totalActualRows == 12)
        #expect(loops.children[1].totalActualRows == 0)
        #expect(scan.properties["Buffer Gets"] == "8")
        #expect(loops.children[1].properties["Execution"] == String(localized: "Never executed"))
        #expect(loops.children[1].actualTotalTime == nil)
        #expect(plan.executionTime == 4)
    }

    @Test("A row a step returns once over many starts is counted once, not rounded away")
    func keepsExactTotalOverManyStarts() throws {
        let plan = try #require(parser.parse(rawText: #"[{"ID":0,"OPERATION":"INDEX","LAST_STARTS":10,"LAST_OUTPUT_ROWS":1}]"#))
        #expect(plan.rootNode.actualRows == 0)
        #expect(plan.rootNode.totalActualRows == 1)
    }

    @Test("Numbers sent as text still read as numbers")
    func numericTextReads() throws {
        let plan = try #require(parser.parse(rawText: #"[{"ID":"0","OPERATION":"SELECT STATEMENT","COST":"12.5","CARDINALITY":"7"}]"#))
        #expect(plan.rootNode.estimatedTotalCost == 12.5)
        #expect(plan.rootNode.estimatedRows == 7)
    }

    @Test("Anything that is not a JSON array of plan rows is not a plan", arguments: ["", "[]", "{}", "not json", #"[{"OPERATION":"X"}]"#])
    func rejectsOtherText(text: String) {
        #expect(parser.parse(rawText: text) == nil)
    }

    @Test("The registry reads the Oracle format with this parser")
    func registryRoutesFormat() {
        #expect(ExplainPlanParserRegistry.parser(for: .oraclePlanRows) is OraclePlanParser)
    }
}
