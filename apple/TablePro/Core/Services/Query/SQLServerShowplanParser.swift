//
//  SQLServerShowplanParser.swift
//  TablePro
//

import Foundation

struct SQLServerShowplanParser: QueryPlanParser {
    private static let documentStart = "<ShowPlanXML"

    func parse(rawText: String) -> QueryPlan? {
        var statements: [SQLServerShowplanReader.Statement] = []
        for document in Self.documents(in: rawText) {
            guard let data = document.data(using: .utf8) else { continue }
            let reader = SQLServerShowplanReader()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            guard parser.parse() else { continue }
            statements += reader.statements
        }

        guard let root = QueryPlanTreeBuilder.root(from: statements.map(\.root)) else { return nil }
        let compileTimes = statements.compactMap(\.compileTime)
        let elapsedTimes = statements.compactMap(\.elapsedTime)
        var plan = QueryPlan(
            rootNode: root,
            planningTime: compileTimes.isEmpty ? nil : compileTimes.reduce(0, +),
            executionTime: elapsedTimes.isEmpty ? nil : elapsedTimes.reduce(0, +),
            rawText: rawText
        )
        plan.computeCostFractions()
        return plan
    }

    static func documents(in rawText: String) -> [String] {
        var documents: [String] = []
        var remaining = rawText[...]
        while let start = remaining.range(of: documentStart) {
            let afterStart = remaining[start.upperBound...]
            let end = afterStart.range(of: documentStart)?.lowerBound ?? remaining.endIndex
            documents.append(String(remaining[start.lowerBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[end...]
        }
        return documents
    }
}

// A RelOp's children sit inside its operator element, so the innermost open RelOp is the parent of the next one.
final class SQLServerShowplanReader: NSObject, XMLParserDelegate {
    struct Statement {
        let root: QueryPlanNode
        let compileTime: Double?
        let elapsedTime: Double?
    }

    private struct Counters {
        var rows = 0.0
        var executions = 0.0
        var elapsedMilliseconds: Double?
        var logicalReads: Double?
    }

    private final class Operator {
        let attributes: [String: String]
        var object: [String: String]?
        var counters: Counters?
        var predicate: String?
        var warnings: [String] = []
        var children: [QueryPlanNode] = []

        init(attributes: [String: String]) {
            self.attributes = attributes
        }
    }

    private final class PendingStatement {
        var compileTime: Double?
        var elapsedTime: Double?
        var warnings: [String] = []
        var missingIndexes: [QueryPlanMissingIndex] = []
        var roots: [QueryPlanNode] = []
    }

    private final class PendingMissingIndex {
        let impact: Double?
        var table: [String: String] = [:]
        var columns: [String: [String]] = [:]
        var usage: String?

        init(impact: Double?) {
            self.impact = impact
        }
    }

    private static let maximumDepth = 512

    private(set) var statements: [Statement] = []
    private var path: [String] = []
    private var operators: [Operator] = []
    private var statement: PendingStatement?
    private var missingIndexImpact: Double?
    private var missingIndex: PendingMissingIndex?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parent = path.last
        path.append(elementName)
        guard path.count < Self.maximumDepth else {
            parser.abortParsing()
            return
        }

        switch elementName {
        case "QueryPlan" where operators.isEmpty:
            let pending = PendingStatement()
            pending.compileTime = attributeDict["CompileTime"].flatMap(Double.init)
            statement = pending
        case "QueryTimeStats" where operators.isEmpty:
            statement?.elapsedTime = attributeDict["ElapsedTime"].flatMap(Double.init)
        case "RelOp":
            operators.append(Operator(attributes: attributeDict))
        case "Object":
            if let current = operators.last, current.object == nil { current.object = attributeDict }
        case "RunTimeCountersPerThread":
            operators.last.map { Self.add(attributeDict, to: $0) }
        case "ScalarOperator" where parent == "Predicate":
            if let current = operators.last, current.predicate == nil { current.predicate = attributeDict["ScalarString"] }
        case "MissingIndexGroup":
            missingIndexImpact = attributeDict["Impact"].flatMap(Double.init)
        case "MissingIndex":
            let pending = PendingMissingIndex(impact: missingIndexImpact)
            pending.table = attributeDict
            missingIndex = pending
        case "ColumnGroup":
            missingIndex?.usage = attributeDict["Usage"]
        case "Column" where parent == "ColumnGroup":
            if let missingIndex, let usage = missingIndex.usage, let name = attributeDict["Name"] {
                missingIndex.columns[usage, default: []].append(name)
            }
        default:
            break
        }

        if parent == "Warnings" || elementName == "Warnings" {
            recordWarning(elementName, attributes: attributeDict)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        path.removeLast()
        switch elementName {
        case "RelOp":
            guard let finished = operators.popLast() else { return }
            let node = Self.node(from: finished)
            if let parent = operators.last {
                parent.children.append(node)
            } else {
                statement?.roots.append(node)
            }
        case "MissingIndex":
            if let missingIndex, let created = Self.missingIndex(from: missingIndex) {
                statement?.missingIndexes.append(created)
            }
            missingIndex = nil
        case "QueryPlan" where operators.isEmpty:
            finishStatement()
        default:
            break
        }
    }

    private func finishStatement() {
        guard let pending = statement else { return }
        statement = nil
        guard var root = QueryPlanTreeBuilder.root(from: pending.roots) else { return }
        root.warnings += pending.warnings
        root.missingIndexes += pending.missingIndexes
        statements.append(Statement(root: root, compileTime: pending.compileTime, elapsedTime: pending.elapsedTime))
    }

    private func recordWarning(_ elementName: String, attributes: [String: String]) {
        let texts = elementName == "Warnings"
            ? attributes.filter { $0.value == "true" || $0.value == "1" }.keys.sorted().map(Self.words)
            : [Self.warningText(elementName, attributes: attributes)]
        guard !texts.isEmpty else { return }
        if let current = operators.last {
            current.warnings += texts
        } else {
            statement?.warnings += texts
        }
    }

    private static func warningText(_ elementName: String, attributes: [String: String]) -> String {
        switch elementName {
        case "PlanAffectingConvert":
            let issue = attributes["ConvertIssue"].map { " (\($0))" } ?? ""
            return "Implicit conversion\(issue): \(attributes["Expression"] ?? "")"
        case "SpillToTempDb":
            let level = attributes["SpillLevel"].map { ", level \($0)" } ?? ""
            return "Spill to tempdb\(level)"
        case "ColumnsWithNoStatistics":
            return "Columns with no statistics"
        default:
            return words(elementName)
        }
    }

    private static func words(_ identifier: String) -> String {
        var result = ""
        for (index, character) in identifier.enumerated() {
            if index > 0, character.isUppercase { result.append(" ") }
            result.append(index > 0 ? Character(character.lowercased()) : character)
        }
        return result
    }

    private static func add(_ attributes: [String: String], to target: Operator) {
        var counters = target.counters ?? Counters()
        counters.rows += attributes["ActualRows"].flatMap(Double.init) ?? 0
        counters.executions += attributes["ActualExecutions"].flatMap(Double.init) ?? 0
        if let elapsed = attributes["ActualElapsedms"].flatMap(Double.init) {
            counters.elapsedMilliseconds = max(counters.elapsedMilliseconds ?? 0, elapsed)
        }
        if let reads = attributes["ActualLogicalReads"].flatMap(Double.init) {
            counters.logicalReads = (counters.logicalReads ?? 0) + reads
        }
        target.counters = counters
    }

    private static func node(from source: Operator) -> QueryPlanNode {
        let attributes = source.attributes
        var properties: [String: String] = [:]
        let physical = attributes["PhysicalOp"] ?? "Unknown"
        if let logical = attributes["LogicalOp"], logical != physical { properties["Logical Operation"] = logical }
        if let index = source.object?["Index"] { properties["Index Name"] = unbracketed(index) }
        properties["Index Kind"] = source.object?["IndexKind"]
        properties["Predicate"] = source.predicate
        properties["Execution Mode"] = attributes["EstimatedExecutionMode"]
        if attributes["Parallel"] == "1" || attributes["Parallel"] == "true" { properties["Parallel"] = "true" }
        properties["Estimated I/O"] = attributes["EstimateIO"]
        properties["Estimated CPU"] = attributes["EstimateCPU"]
        let rebinds = attributes["EstimateRebinds"].flatMap(Double.init) ?? 0
        let rewinds = attributes["EstimateRewinds"].flatMap(Double.init) ?? 0
        if rebinds + rewinds > 0 {
            properties["Estimated Executions"] = String(format: "%g", 1 + rebinds + rewinds)
        }

        // The counters total every execution and thread; the plan model holds per-execution values.
        var actualRows: Int?
        var actualTime: Double?
        var actualLoops: Int?
        if let counters = source.counters {
            actualLoops = boundedInt(counters.executions)
            if counters.executions > 0 {
                actualRows = boundedInt(counters.rows / counters.executions)
                actualTime = counters.elapsedMilliseconds.map { $0 / counters.executions }
            } else {
                properties["Execution"] = String(localized: "Never executed")
            }
            properties["Logical Reads"] = counters.logicalReads.flatMap(boundedInt).map(String.init)
        }

        var node = QueryPlanNode(
            operation: physical,
            relation: source.object?["Table"].map(unbracketed),
            schema: source.object?["Schema"].map(unbracketed),
            alias: source.object?["Alias"].map(unbracketed),
            estimatedStartupCost: nil,
            estimatedTotalCost: attributes["EstimatedTotalSubtreeCost"].flatMap(Double.init),
            estimatedRows: attributes["EstimateRows"].flatMap(Double.init).flatMap(boundedInt),
            estimatedWidth: attributes["AvgRowSize"].flatMap(Int.init),
            actualStartupTime: nil,
            actualTotalTime: actualTime,
            actualRows: actualRows,
            actualLoops: actualLoops,
            properties: properties,
            children: source.children
        )
        node.warnings = source.warnings
        node.reportedTotalActualRows = source.counters.flatMap { boundedInt($0.rows) }
        return node
    }

    // Equality columns lead the key, then inequality ones, the order the server builds its own suggestion in.
    private static func missingIndex(from pending: PendingMissingIndex) -> QueryPlanMissingIndex? {
        let keys = (pending.columns["EQUALITY"] ?? []) + (pending.columns["INEQUALITY"] ?? [])
        guard !keys.isEmpty, let table = pending.table["Table"] else { return nil }
        let qualified = [pending.table["Database"], pending.table["Schema"], table].compactMap { $0 }.joined(separator: ".")
        let nameParts = [unbracketed(table)] + keys.map(unbracketed)
        let name = "IX_" + String(nameParts.joined(separator: "_").map { $0.isLetter || $0.isNumber ? $0 : "_" })
        var statement = "CREATE NONCLUSTERED INDEX [\(String(name.prefix(128)))] ON \(qualified) (\(keys.joined(separator: ", ")))"
        if let included = pending.columns["INCLUDE"], !included.isEmpty {
            statement += " INCLUDE (\(included.joined(separator: ", ")))"
        }
        return QueryPlanMissingIndex(impact: pending.impact, createStatement: statement + ";")
    }

    // An estimate past Int.max, which a large cross join can reach, is left out rather than trapping.
    private static func boundedInt(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    private static func unbracketed(_ name: String) -> String {
        guard name.hasPrefix("["), name.hasSuffix("]"), name.count >= 2 else { return name }
        return String(name.dropFirst().dropLast()).replacingOccurrences(of: "]]", with: "]")
    }
}
