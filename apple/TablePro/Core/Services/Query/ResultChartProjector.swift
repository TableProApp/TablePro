//
//  ResultChartProjector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

actor ResultChartProjector {
    static let shared = ResultChartProjector()
    static let maximumPointCount = 2_000
    static let maximumSeriesCount = 20
    static let maximumFacetCount = 12
    static let maximumInspectedRowCount = 50_000
    static let maximumLabelLength = 512
    static let maximumNumericLength = 256

    private enum XOccurrenceKey: Hashable {
        case category(String)
        case number(String)
        case date(Date)
    }

    private struct BarOccurrenceKey: Hashable {
        let facet: Int
        let x: XOccurrenceKey
        let series: Int
    }

    /// Not keyed by facet: a series keeps the same slot in every panel, so its bars sit in the same
    /// place wherever it appears.
    private struct BarGroupKey: Hashable {
        let series: Int
        let occurrence: Int
    }

    private struct LineKey: Hashable {
        let facet: ResultChartProjection.GroupValue?
        let series: ResultChartProjection.GroupValue?
    }

    private struct LineGroupKey: Hashable {
        let facet: Int
        let series: Int
        let generation: Int
    }

    /// Which group of one column a row belongs to, if it can be told.
    private enum Attribution {
        case ungrouped
        case group(ResultChartProjection.GroupValue)
        case unreadable

        /// Nil when the cell cannot be read; `.some(nil)` when the chart does not group by it.
        var groupValue: ResultChartProjection.GroupValue?? {
            switch self {
            case .ungrouped: return .some(nil)
            case .group(let value): return value
            case .unreadable: return nil
            }
        }

        func couldOwn(_ line: ResultChartProjection.GroupValue?) -> Bool {
            switch self {
            case .ungrouped: return line == nil
            case .group(let value): return line == value
            case .unreadable: return true
            }
        }
    }

    private struct RowValues {
        let x: ResultChartProjection.XValue
        let rawX: String
        let y: Double
        let rawY: String
    }

    /// A point before labels exist. Labels have to be unique across the whole projection, so they
    /// are assigned once every group is known.
    private struct PendingPoint {
        let sourceIndex: Int
        let values: RowValues
        let series: ResultChartProjection.GroupValue?
        let facet: ResultChartProjection.GroupValue?
        let barGroup: Int
        let lineGroup: Int
    }

    private struct Ordinals {
        private(set) var values: [ResultChartProjection.GroupValue: Int] = [:]
        let limit: Int

        /// Nil when the value is new and the cap is reached. Nothing is recorded until `commit`, so
        /// a row dropped by another cap does not use up a slot here.
        func ordinal(for value: ResultChartProjection.GroupValue) -> Int? {
            if let ordinal = values[value] { return ordinal }
            return values.count < limit ? values.count : nil
        }

        mutating func commit(_ value: ResultChartProjection.GroupValue, as ordinal: Int) {
            values[value] = ordinal
        }
    }

    /// Cancellation is the only failure this can report, and saying so in the signature keeps it
    /// that way: a caller cannot be handed an error state that never arrives.
    func project(
        tableRows: TableRows,
        configuration: ResultChartConfiguration.Resolved
    ) async throws(CancellationError) -> ResultChartProjection {
        var pending: [PendingPoint] = []
        pending.reserveCapacity(min(tableRows.rows.count, Self.maximumPointCount))
        var seriesOrdinals = Ordinals(limit: Self.maximumSeriesCount)
        var facetOrdinals = Ordinals(limit: Self.maximumFacetCount)
        var xOccurrences: [BarOccurrenceKey: Int] = [:]
        var barGroupOrdinals: [BarGroupKey: Int] = [:]
        var lineGroupOrdinals: [LineGroupKey: Int] = [:]
        var lineBreakGenerations: [LineKey: Int] = [:]
        var drawnLines: Set<LineKey> = []
        var limits: [ResultChartProjection.Limit] = []
        var skippedRowCount = 0

        rows: for (sourceIndex, row) in tableRows.rows.enumerated() {
            if sourceIndex == Self.maximumInspectedRowCount {
                limits.append(.inspectedRows(limit: Self.maximumInspectedRowCount))
                break
            }
            if sourceIndex.isMultiple(of: 256), Task.isCancelled {
                throw CancellationError()
            }

            let facet = attribution(of: row, column: configuration.facetColumn)
            let series = attribution(of: row, column: configuration.seriesColumn)
            guard let values = rowValues(in: row, sourceIndex: sourceIndex, configuration: configuration),
                  let facetValue = facet.groupValue,
                  let seriesValue = series.groupValue
            else {
                skippedRowCount += 1
                recordLineBreak(facet: facet, series: series, drawnLines: drawnLines, generations: &lineBreakGenerations)
                continue
            }

            var facetOrdinal = 0
            if let facetValue {
                guard let ordinal = facetOrdinals.ordinal(for: facetValue) else {
                    appendOnce(.facets(limit: Self.maximumFacetCount), to: &limits)
                    continue
                }
                facetOrdinal = ordinal
            }
            var seriesOrdinal = 0
            if let seriesValue {
                guard let ordinal = seriesOrdinals.ordinal(for: seriesValue) else {
                    appendOnce(.series(limit: Self.maximumSeriesCount), to: &limits)
                    continue
                }
                seriesOrdinal = ordinal
            }

            if pending.count == Self.maximumPointCount {
                limits.append(.points(limit: Self.maximumPointCount))
                break rows
            }
            if let facetValue { facetOrdinals.commit(facetValue, as: facetOrdinal) }
            if let seriesValue { seriesOrdinals.commit(seriesValue, as: seriesOrdinal) }

            let occurrenceKey = BarOccurrenceKey(
                facet: facetOrdinal,
                x: stableXKey(values.x, raw: values.rawX),
                series: seriesOrdinal
            )
            xOccurrences[occurrenceKey, default: 0] += 1
            let occurrence = xOccurrences[occurrenceKey, default: 1]
            let lineKey = LineKey(facet: facetValue, series: seriesValue)
            drawnLines.insert(lineKey)
            let lineGroupKey = LineGroupKey(
                facet: facetOrdinal,
                series: seriesOrdinal,
                generation: lineBreakGenerations[lineKey, default: 0]
            )
            pending.append(PendingPoint(
                sourceIndex: sourceIndex,
                values: values,
                series: seriesValue,
                facet: facetValue,
                barGroup: ordinal(for: BarGroupKey(series: seriesOrdinal, occurrence: occurrence), in: &barGroupOrdinals),
                lineGroup: ordinal(for: lineGroupKey, in: &lineGroupOrdinals)
            ))
        }

        return ResultChartProjection(
            points: labeledPoints(pending),
            xAxisKind: configuration.xAxisKind,
            limits: limits,
            loadedRowCount: tableRows.rows.count,
            skippedRowCount: skippedRowCount,
            xAxisLabel: configuration.xColumn?.displayName ?? String(localized: "Row Number"),
            yAxisLabel: configuration.yColumn.displayName,
            seriesLabel: configuration.seriesColumn?.displayName,
            facetLabel: configuration.facetColumn?.displayName,
            sharesXAxis: configuration.xColumn != nil
        )
    }

    private func labeledPoints(_ pending: [PendingPoint]) -> [ResultChartProjection.Point] {
        let series = groups(pending.compactMap(\.series))
        let facets = groups(pending.compactMap(\.facet))
        var categories: [String] = []
        var seenCategories: Set<String> = []
        for point in pending {
            if case .category(let raw) = point.values.x, seenCategories.insert(raw).inserted {
                categories.append(raw)
            }
        }
        let categoryLabels = Dictionary(uniqueKeysWithValues: zip(
            categories,
            ResultChartProjection.Group.labeled(categories.map { .value($0) }).map(\.label)
        ))

        return pending.map { point in
            var x = point.values.x
            if case .category(let raw) = x { x = .category(categoryLabels[raw] ?? raw) }
            return ResultChartProjection.Point(
                sourceIndex: point.sourceIndex,
                x: x,
                y: point.values.y,
                rawX: point.values.rawX,
                rawY: point.values.rawY,
                series: point.series.flatMap { series[$0] },
                facet: point.facet.flatMap { facets[$0] },
                barGroup: point.barGroup,
                lineGroup: point.lineGroup
            )
        }
    }

    private func groups(
        _ values: [ResultChartProjection.GroupValue]
    ) -> [ResultChartProjection.GroupValue: ResultChartProjection.Group] {
        Dictionary(uniqueKeysWithValues: ResultChartProjection.Group.labeled(Array(Set(values))).map { ($0.value, $0) })
    }

    private func appendOnce(
        _ limit: ResultChartProjection.Limit,
        to limits: inout [ResultChartProjection.Limit]
    ) {
        guard !limits.contains(limit) else { return }
        limits.append(limit)
    }

    private func rowValues(
        in row: Row,
        sourceIndex: Int,
        configuration: ResultChartConfiguration.Resolved
    ) -> RowValues? {
        guard let x = xValue(from: row, sourceIndex: sourceIndex, column: configuration.xColumn),
              let yCell = cell(in: row, at: configuration.yColumn.index),
              let y = numericValue(from: yCell)
        else {
            return nil
        }
        return RowValues(x: x.value, rawX: x.raw, y: y.value, rawY: y.raw)
    }

    private func xValue(
        from row: Row,
        sourceIndex: Int,
        column: ResultChartColumn?
    ) -> (value: ResultChartProjection.XValue, raw: String)? {
        guard let column else {
            let number = sourceIndex + 1
            return (.number(Double(number)), String(number))
        }
        guard let cell = cell(in: row, at: column.index) else { return nil }

        switch column.xAxisKind {
        case .category:
            guard case .text(let raw) = cell,
                  raw.utf8.count <= Self.maximumLabelLength else { return nil }
            return (.category(raw), raw)
        case .number:
            guard let number = numericValue(from: cell) else { return nil }
            return (.number(number.value), number.raw)
        case .date:
            guard case .text(let raw) = cell,
                  raw.utf8.count <= Self.maximumLabelLength,
                  let parsed = DatabaseDateParser.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return nil
            }
            return (.date(parsed.plottableDate), raw)
        case nil:
            return nil
        }
    }

    /// Swift Charts plots `Double`, so the value the chart draws is the value validated here.
    /// `Decimal` would add a second conversion through `NSDecimalNumber`, which is not correctly
    /// rounded and rejected 28% of ordinary two-decimal money values.
    private func numericValue(from cell: PluginCellValue) -> (value: Double, raw: String)? {
        guard case .text(let raw) = cell else { return nil }
        guard raw.utf8.count <= Self.maximumNumericLength else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = JsonNumberNormalizer.numberLiteral(from: trimmed),
              let value = Double(normalized),
              value.isFinite,
              canonicalNumericKey(normalized) == canonicalNumericKey(String(value))
        else {
            return nil
        }
        return (value, raw)
    }

    private func canonicalNumericKey(_ value: String) -> String? {
        guard let normalized = JsonNumberNormalizer.numberLiteral(from: value) else { return nil }
        let isNegative = normalized.first == "-"
        let unsigned = isNegative ? normalized.dropFirst() : Substring(normalized)
        let exponentParts = unsigned.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        guard let mantissa = exponentParts.first,
              exponentParts.count < 2 || Int(exponentParts[1]) != nil
        else {
            return nil
        }

        let explicitExponent = exponentParts.count == 2 ? Int(exponentParts[1]) ?? 0 : 0
        let decimalParts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fractionalCount = decimalParts.count == 2 ? decimalParts[1].count : 0
        var digits = Array(decimalParts.joined())
        while digits.first == "0" { digits.removeFirst() }
        guard !digits.isEmpty else { return "0" }

        var exponent = explicitExponent - fractionalCount
        while digits.last == "0" {
            digits.removeLast()
            exponent += 1
        }
        return "\(isNegative ? "-" : "")\(String(digits))e\(exponent)"
    }

    private func attribution(of row: Row, column: ResultChartColumn?) -> Attribution {
        guard let column else { return .ungrouped }
        guard let cell = cell(in: row, at: column.index), let value = groupValue(from: cell) else {
            return .unreadable
        }
        return .group(value)
    }

    private func groupValue(from cell: PluginCellValue) -> ResultChartProjection.GroupValue? {
        switch cell {
        case .null:
            return .missing
        case .text(let value):
            guard value.utf8.count <= Self.maximumLabelLength else { return nil }
            return .value(value)
        case .bytes:
            return nil
        }
    }

    /// A skipped row is a hole in the line, so the next point starts a new segment rather than the
    /// line being drawn straight through it. When a group cell is the unreadable one the row cannot
    /// be attributed, so every line it could belong to breaks: the alternative is drawing over a
    /// discontinuity in whichever line it really belonged to.
    private func recordLineBreak(
        facet: Attribution,
        series: Attribution,
        drawnLines: Set<LineKey>,
        generations: inout [LineKey: Int]
    ) {
        if let facetValue = facet.groupValue, let seriesValue = series.groupValue {
            generations[LineKey(facet: facetValue, series: seriesValue), default: 0] += 1
            return
        }
        for line in drawnLines where facet.couldOwn(line.facet) && series.couldOwn(line.series) {
            generations[line, default: 0] += 1
        }
    }

    private func cell(in row: Row, at index: Int) -> PluginCellValue? {
        guard row.values.indices.contains(index) else { return nil }
        return row.values[index]
    }

    private func stableXKey(_ value: ResultChartProjection.XValue, raw: String) -> XOccurrenceKey {
        switch value {
        case .category: return .category(raw)
        case .number: return .number(canonicalNumericKey(raw) ?? raw)
        case .date(let date): return .date(date)
        }
    }

    private func ordinal<Key: Hashable>(for key: Key, in ordinals: inout [Key: Int]) -> Int {
        if let ordinal = ordinals[key] { return ordinal }
        let ordinal = ordinals.count
        ordinals[key] = ordinal
        return ordinal
    }
}
