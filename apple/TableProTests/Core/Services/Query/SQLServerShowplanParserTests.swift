//
//  SQLServerShowplanParserTests.swift
//  TableProTests
//
//  The fixtures keep the shape SQL Server 2022 (16.0.4135) returned for a three-table join, trimmed to the elements
//  the parser reads.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLServerShowplanParserTests {
    private let parser = SQLServerShowplanParser()

    private static let ns = #"xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4135.4""#

    private static let actual = """
        <ShowPlanXML \(ns)><BatchSequence><Batch><Statements>\
        <StmtSimple StatementText="SELECT c.name FROM customers c JOIN orders o ON o.customer_id = c.id" StatementType="SELECT" StatementSubTreeCost="0.104866">\
        <QueryPlan DegreeOfParallelism="1" CompileTime="249">\
        <Warnings><PlanAffectingConvert ConvertIssue="Seek Plan" Expression="CONVERT_IMPLICIT(nvarchar(50),[c].[city],0)=N'city7'"/></Warnings>\
        <QueryTimeStats ElapsedTime="114" CpuTime="114"/>\
        <RelOp NodeId="0" PhysicalOp="Hash Match" LogicalOp="Inner Join" EstimateRows="213.12" EstimateIO="0" EstimateCPU="0.0405522" AvgRowSize="132" EstimatedTotalSubtreeCost="0.104866" Parallel="0" EstimateRebinds="0" EstimateRewinds="0" EstimatedExecutionMode="Row">\
        <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="14" ActualElapsedms="33" ActualEndOfScans="1" ActualExecutions="1"/></RunTimeInformation>\
        <Hash><DefinedValues/>\
        <RelOp NodeId="1" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="80" AvgRowSize="122" EstimatedTotalSubtreeCost="0.0114079" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">\
        <Warnings NoJoinPredicate="1"/>\
        <RunTimeInformation>\
        <RunTimeCountersPerThread Thread="1" ActualRows="30" ActualElapsedms="2" ActualLogicalReads="5" ActualExecutions="2"/>\
        <RunTimeCountersPerThread Thread="2" ActualRows="10" ActualElapsedms="3" ActualLogicalReads="6" ActualExecutions="2"/>\
        </RunTimeInformation>\
        <IndexScan Ordered="0"><DefinedValues/>\
        <Object Database="[probe]" Schema="[dbo]" Table="[customers]" Index="[PK__customer]" Alias="[c]" IndexKind="Clustered"/>\
        <Predicate><ScalarOperator ScalarString="[probe].[dbo].[customers].[city] as [c].[city]='city7'"><Const ConstValue="'city7'"/></ScalarOperator></Predicate>\
        </IndexScan></RelOp>\
        <RelOp NodeId="2" PhysicalOp="Sort" LogicalOp="Sort" EstimateRows="40" AvgRowSize="20" EstimatedTotalSubtreeCost="0.05" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">\
        <Warnings><SpillToTempDb SpillLevel="1" SpilledThreadCount="1"/></Warnings>\
        <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="0" ActualExecutions="0"/></RunTimeInformation>\
        <Sort Distinct="0"><RelOp NodeId="3" PhysicalOp="Table Scan" LogicalOp="Table Scan" EstimateRows="40" AvgRowSize="20" EstimatedTotalSubtreeCost="0.01" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">\
        <TableScan><Object Database="[probe]" Schema="[dbo]" Table="[orders]" Alias="[o]"/></TableScan></RelOp></Sort>\
        </RelOp>\
        </Hash></RelOp>\
        </QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>
        """

    private static let missingIndex = """
        <ShowPlanXML \(ns)><BatchSequence><Batch><Statements>\
        <StmtSimple StatementText="SELECT id FROM orders WHERE status = 'open' AND total &gt; 10" StatementType="SELECT">\
        <QueryPlan CompileTime="2">\
        <MissingIndexes><MissingIndexGroup Impact="93.5"><MissingIndex Database="[probe]" Schema="[dbo]" Table="[orders]">\
        <ColumnGroup Usage="EQUALITY"><Column Name="[status]" ColumnId="4"/></ColumnGroup>\
        <ColumnGroup Usage="INEQUALITY"><Column Name="[total]" ColumnId="3"/></ColumnGroup>\
        <ColumnGroup Usage="INCLUDE"><Column Name="[id]" ColumnId="1"/></ColumnGroup>\
        </MissingIndex></MissingIndexGroup></MissingIndexes>\
        <RelOp NodeId="0" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="12" AvgRowSize="11" EstimatedTotalSubtreeCost="0.0114" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">\
        <IndexScan><Object Database="[probe]" Schema="[dbo]" Table="[orders]" Index="[PK_orders]"/></IndexScan></RelOp>\
        </QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>
        """

    @Test("A RelOp nested inside its parent's operator element becomes that parent's child")
    func nestsRelOps() throws {
        let plan = try #require(parser.parse(rawText: Self.actual))

        #expect(plan.rootNode.operation == "Hash Match")
        #expect(plan.rootNode.properties["Logical Operation"] == "Inner Join")
        #expect(plan.rootNode.children.map { $0.operation } == ["Clustered Index Scan", "Sort"])
        #expect(plan.rootNode.children[1].children.map { $0.operation } == ["Table Scan"])
    }

    @Test("Object, index, estimates and the residual predicate land where the plan views read them")
    func mapsEstimates() throws {
        let plan = try #require(parser.parse(rawText: Self.actual))
        let scan = plan.rootNode.children[0]

        #expect(scan.relation == "customers")
        #expect(scan.schema == "dbo")
        #expect(scan.alias == "c")
        #expect(scan.properties["Index Name"] == "PK__customer")
        #expect(scan.properties["Predicate"] == "[probe].[dbo].[customers].[city] as [c].[city]='city7'")
        #expect(scan.estimatedTotalCost == 0.0114079)
        #expect(scan.estimatedRows == 80)
        #expect(scan.estimatedWidth == 122)
        #expect(plan.rootNode.estimatedRows == 213)
        #expect(plan.planningTime == 249)
        #expect(plan.executionTime == 114)
        #expect(plan.rootNode.costFraction != nil)
    }

    @Test("Run-time counters total every thread and execution, and read back per execution")
    func countersArePerExecution() throws {
        let plan = try #require(parser.parse(rawText: Self.actual))
        let scan = plan.rootNode.children[0]

        #expect(scan.actualLoops == 4)
        #expect(scan.actualRows == 10)
        #expect(scan.actualTotalTime == 0.75)
        #expect(scan.totalActualRows == 40)
        #expect(plan.rootNode.children[1].totalActualRows == 0)
        #expect(scan.properties["Logical Reads"] == "11")
        #expect(plan.rootNode.actualRows == 14)
        #expect(plan.rootNode.actualTotalTime == 33)
        #expect(plan.rootNode.children[1].properties["Execution"] == String(localized: "Never executed"))
    }

    @Test("A warning lands on the node it belongs to, and a statement warning on the statement's root")
    func placesWarnings() throws {
        let plan = try #require(parser.parse(rawText: Self.actual))

        #expect(plan.rootNode.warnings == [
            "Implicit conversion (Seek Plan): CONVERT_IMPLICIT(nvarchar(50),[c].[city],0)=N'city7'"
        ])
        #expect(plan.rootNode.children[0].warnings == ["No join predicate"])
        #expect(plan.rootNode.children[1].warnings == ["Spill to tempdb, level 1"])
        #expect(plan.rootNode.children[1].children[0].warnings.isEmpty)
    }

    @Test("A missing index becomes a CREATE INDEX with equality columns first and the included ones after")
    func buildsMissingIndex() throws {
        let plan = try #require(parser.parse(rawText: Self.missingIndex))

        #expect(plan.rootNode.missingIndexes == [
            QueryPlanMissingIndex(
                impact: 93.5,
                createStatement: "CREATE NONCLUSTERED INDEX [IX_orders_status_total] ON [probe].[dbo].[orders] ([status], [total]) INCLUDE ([id]);"
            )
        ])
    }

    @Test("One document per statement the server planned, under one root")
    func readsSeveralDocuments() throws {
        let plan = try #require(parser.parse(rawText: Self.actual + "\n" + Self.missingIndex))

        #expect(plan.rootNode.operation == "Query Plan")
        #expect(plan.rootNode.children.map { $0.operation } == ["Hash Match", "Clustered Index Scan"])
        #expect(plan.planningTime == 251)
    }

    @Test("An estimate past Int.max is left out rather than trapping")
    func hugeEstimateIsLeftOut() throws {
        let huge = Self.missingIndex.replacingOccurrences(of: #"EstimateRows="12""#, with: #"EstimateRows="1e20""#)
        let plan = try #require(parser.parse(rawText: huge))
        #expect(plan.rootNode.estimatedRows == nil)
        #expect(plan.rootNode.estimatedTotalCost == 0.0114)
    }

    @Test("Text that holds no showplan is not a plan", arguments: ["", "not xml", "<ShowPlanXML", "<Other/>"])
    func rejectsOtherText(text: String) {
        #expect(parser.parse(rawText: text) == nil)
    }

    @Test("The registry reads the SQL Server format with this parser")
    func registryRoutesFormat() {
        #expect(ExplainPlanParserRegistry.parser(for: .sqlServerShowplanXML) is SQLServerShowplanParser)
    }
}
