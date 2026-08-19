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
    static let maximumInspectedRowCount = 50_000
    static let maximumLabelLength = 512
    static let maximumNumericLength = 256

    private enum XOccurrenceKey: Hashable {
        case category(String)
        case number(String)
    }

    private struct GroupKey: Hashable {
        let series: Int
        let occurrence: Int
    }

    private struct BarOccurrenceKey: Hashable {
        let x: XOccurrenceKey
        let series: Int
    }

    private enum LineSeriesKey: Hashable {
        case ungrouped
        case series(ResultChartProjection.SeriesValue)
    }

    func project(
        tableRows: TableRows,
        configuration: ResultChartConfiguration.Resolved
    ) async throws -> ResultChartProjection {
        var points: [ResultChartProjection.Point] = []
        points.reserveCapacity(min(tableRows.rows.count, Self.maximumPointCount))
        var seriesOrdinals: [ResultChartProjection.SeriesValue: Int] = [:]
        var xOccurrences: [BarOccurrenceKey: Int] = [:]
        var barGroupOrdinals: [GroupKey: Int] = [:]
        var lineGroupOrdinals: [GroupKey: Int] = [:]
        var lineBreakGenerations: [LineSeriesKey: Int] = [:]
        var skippedRowCount = 0

        for (sourceIndex, row) in tableRows.rows.enumerated() {
            if sourceIndex == Self.maximumInspectedRowCount {
                return issueProjection(
                    .tooManyRows(limit: Self.maximumInspectedRowCount),
                    tableRows: tableRows,
                    configuration: configuration,
                    skippedRowCount: skippedRowCount
                )
            }
            if sourceIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard let x = xValue(from: row, sourceIndex: sourceIndex, column: configuration.xColumn),
                  let yCell = cell(in: row, at: configuration.yColumn.index),
                  let y = numericValue(from: yCell)
            else {
                skippedRowCount += 1
                recordLineBreak(
                    for: row,
                    seriesColumn: configuration.seriesColumn,
                    generations: &lineBreakGenerations
                )
                continue
            }

            let series: ResultChartProjection.SeriesValue?
            let seriesOrdinal: Int
            if let seriesColumn = configuration.seriesColumn {
                guard let cell = cell(in: row, at: seriesColumn.index),
                      let value = seriesValue(from: cell)
                else {
                    skippedRowCount += 1
                    continue
                }
                series = value
                if let ordinal = seriesOrdinals[value] {
                    seriesOrdinal = ordinal
                } else {
                    guard seriesOrdinals.count < Self.maximumSeriesCount else {
                        return issueProjection(
                            .tooManySeries(limit: Self.maximumSeriesCount),
                            tableRows: tableRows,
                            configuration: configuration,
                            skippedRowCount: skippedRowCount
                        )
                    }
                    seriesOrdinal = seriesOrdinals.count
                    seriesOrdinals[value] = seriesOrdinal
                }
            } else {
                series = nil
                seriesOrdinal = 0
            }

            if points.count == Self.maximumPointCount {
                return issueProjection(
                    .tooManyPoints(limit: Self.maximumPointCount),
                    tableRows: tableRows,
                    configuration: configuration,
                    skippedRowCount: skippedRowCount
                )
            }

            let xKey = stableXKey(x.value, raw: x.raw)
            let occurrenceKey = BarOccurrenceKey(x: xKey, series: seriesOrdinal)
            xOccurrences[occurrenceKey, default: 0] += 1
            let occurrence = xOccurrences[occurrenceKey, default: 1]
            let barGroupKey = GroupKey(series: seriesOrdinal, occurrence: occurrence)
            let lineSeriesKey = series.map(LineSeriesKey.series) ?? .ungrouped
            let lineGroupKey = GroupKey(
                series: seriesOrdinal,
                occurrence: lineBreakGenerations[lineSeriesKey, default: 0]
            )
            let barGroup = ordinal(for: barGroupKey, in: &barGroupOrdinals)
            let lineGroup = ordinal(for: lineGroupKey, in: &lineGroupOrdinals)
            points.append(ResultChartProjection.Point(
                sourceIndex: sourceIndex,
                x: x.value,
                y: y.value,
                rawX: x.raw,
                rawY: y.raw,
                series: series,
                barGroup: barGroup,
                lineGroup: lineGroup
            ))
        }

        return ResultChartProjection(
            points: points,
            issue: points.isEmpty ? .noChartableRows : nil,
            loadedRowCount: tableRows.rows.count,
            skippedRowCount: skippedRowCount,
            xAxisLabel: configuration.xColumn?.displayName ?? String(localized: "Row Number"),
            yAxisLabel: configuration.yColumn.displayName,
            seriesLabel: configuration.seriesColumn?.displayName
        )
    }

    private func issueProjection(
        _ issue: ResultChartProjection.Issue,
        tableRows: TableRows,
        configuration: ResultChartConfiguration.Resolved,
        skippedRowCount: Int
    ) -> ResultChartProjection {
        ResultChartProjection(
            points: [],
            issue: issue,
            loadedRowCount: tableRows.rows.count,
            skippedRowCount: skippedRowCount,
            xAxisLabel: configuration.xColumn?.displayName ?? String(localized: "Row Number"),
            yAxisLabel: configuration.yColumn.displayName,
            seriesLabel: configuration.seriesColumn?.displayName
        )
    }

    private func xValue(
        from row: Row,
        sourceIndex: Int,
        column: ResultChartColumn?
    ) -> (value: ResultChartProjection.XValue, raw: String)? {
        guard let column else {
            let number = sourceIndex + 1
            return (.number(Decimal(number)), String(number))
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
        case nil:
            return nil
        }
    }

    private func numericValue(from cell: PluginCellValue) -> (value: Decimal, raw: String)? {
        guard case .text(let raw) = cell else { return nil }
        guard raw.utf8.count <= Self.maximumNumericLength else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = JsonNumberNormalizer.numberLiteral(from: trimmed),
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              canonicalNumericKey(normalized) == canonicalNumericKey(NSDecimalNumber(decimal: value).stringValue),
              isExactlyPlottable(value, normalized: normalized)
        else {
            return nil
        }
        return (value, raw)
    }

    private func isExactlyPlottable(_ value: Decimal, normalized: String) -> Bool {
        let primitive = NSDecimalNumber(decimal: value).doubleValue
        guard primitive.isFinite else { return false }
        return canonicalNumericKey(normalized) == canonicalNumericKey(String(primitive))
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

    private func seriesValue(from cell: PluginCellValue) -> ResultChartProjection.SeriesValue? {
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

    private func recordLineBreak(
        for row: Row,
        seriesColumn: ResultChartColumn?,
        generations: inout [LineSeriesKey: Int]
    ) {
        let key: LineSeriesKey
        if let seriesColumn {
            guard let cell = cell(in: row, at: seriesColumn.index),
                  let series = seriesValue(from: cell)
            else {
                return
            }
            key = .series(series)
        } else {
            key = .ungrouped
        }
        generations[key, default: 0] += 1
    }

    private func cell(in row: Row, at index: Int) -> PluginCellValue? {
        guard row.values.indices.contains(index) else { return nil }
        return row.values[index]
    }

    private func stableXKey(_ value: ResultChartProjection.XValue, raw: String) -> XOccurrenceKey {
        switch value {
        case .category: return .category(raw)
        case .number:
            return .number(canonicalNumericKey(raw) ?? raw)
        }
    }

    private func ordinal(for key: GroupKey, in ordinals: inout [GroupKey: Int]) -> Int {
        if let ordinal = ordinals[key] { return ordinal }
        let ordinal = ordinals.count
        ordinals[key] = ordinal
        return ordinal
    }
}
