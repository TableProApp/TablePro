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

    private let dateParser = DatabaseDateParser()

    private enum XOccurrenceKey: Hashable {
        case category(String)
        case number(String)
        case date(Date)
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

    private struct RowValues {
        let x: ResultChartProjection.XValue
        let rawX: String
        let y: Double
        let rawY: String
    }

    /// Cancellation is the only failure this can report, and saying so in the signature keeps it
    /// that way: a caller cannot be handed an error state that never arrives.
    func project(
        tableRows: TableRows,
        configuration: ResultChartConfiguration.Resolved
    ) async throws(CancellationError) -> ResultChartProjection {
        var points: [ResultChartProjection.Point] = []
        points.reserveCapacity(min(tableRows.rows.count, Self.maximumPointCount))
        var seriesOrdinals: [ResultChartProjection.SeriesValue: Int] = [:]
        var xOccurrences: [BarOccurrenceKey: Int] = [:]
        var barGroupOrdinals: [GroupKey: Int] = [:]
        var lineGroupOrdinals: [GroupKey: Int] = [:]
        var lineBreakGenerations: [LineSeriesKey: Int] = [:]
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

            guard let values = rowValues(in: row, sourceIndex: sourceIndex, configuration: configuration) else {
                skippedRowCount += 1
                recordLineBreak(
                    for: row,
                    seriesColumn: configuration.seriesColumn,
                    seriesOrdinals: seriesOrdinals,
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
                    recordLineBreak(
                        for: row,
                        seriesColumn: seriesColumn,
                        seriesOrdinals: seriesOrdinals,
                        generations: &lineBreakGenerations
                    )
                    continue
                }
                series = value
                if let ordinal = seriesOrdinals[value] {
                    seriesOrdinal = ordinal
                } else {
                    guard seriesOrdinals.count < Self.maximumSeriesCount else {
                        appendOnce(.series(limit: Self.maximumSeriesCount), to: &limits)
                        continue
                    }
                    seriesOrdinal = seriesOrdinals.count
                    seriesOrdinals[value] = seriesOrdinal
                }
            } else {
                series = nil
                seriesOrdinal = 0
            }

            if points.count == Self.maximumPointCount {
                limits.append(.points(limit: Self.maximumPointCount))
                break rows
            }

            let xKey = stableXKey(values.x, raw: values.rawX)
            let occurrenceKey = BarOccurrenceKey(x: xKey, series: seriesOrdinal)
            xOccurrences[occurrenceKey, default: 0] += 1
            let occurrence = xOccurrences[occurrenceKey, default: 1]
            let barGroupKey = GroupKey(series: seriesOrdinal, occurrence: occurrence)
            let lineSeriesKey = series.map(LineSeriesKey.series) ?? .ungrouped
            let lineGroupKey = GroupKey(
                series: seriesOrdinal,
                occurrence: lineBreakGenerations[lineSeriesKey, default: 0]
            )
            points.append(ResultChartProjection.Point(
                sourceIndex: sourceIndex,
                x: values.x,
                y: values.y,
                rawX: values.rawX,
                rawY: values.rawY,
                series: series,
                barGroup: ordinal(for: barGroupKey, in: &barGroupOrdinals),
                lineGroup: ordinal(for: lineGroupKey, in: &lineGroupOrdinals)
            ))
        }

        return ResultChartProjection(
            points: points,
            xAxisKind: configuration.xAxisKind,
            limits: limits,
            loadedRowCount: tableRows.rows.count,
            skippedRowCount: skippedRowCount,
            xAxisLabel: configuration.xColumn?.displayName ?? String(localized: "Row Number"),
            yAxisLabel: configuration.yColumn.displayName,
            seriesLabel: configuration.seriesColumn?.displayName
        )
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
                  let date = dateParser.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return nil
            }
            return (.date(date), raw)
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

    /// A skipped row is a hole in the line, so the next point starts a new segment rather than the
    /// line being drawn straight through it. When the series cell is the unreadable one the row
    /// cannot be attributed, so every series seen so far breaks: the alternative is drawing over a
    /// discontinuity in whichever line it really belonged to.
    private func recordLineBreak(
        for row: Row,
        seriesColumn: ResultChartColumn?,
        seriesOrdinals: [ResultChartProjection.SeriesValue: Int],
        generations: inout [LineSeriesKey: Int]
    ) {
        guard let seriesColumn else {
            generations[.ungrouped, default: 0] += 1
            return
        }
        guard let cell = cell(in: row, at: seriesColumn.index),
              let series = seriesValue(from: cell)
        else {
            for value in seriesOrdinals.keys {
                generations[.series(value), default: 0] += 1
            }
            return
        }
        generations[.series(series), default: 0] += 1
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

    private func ordinal(for key: GroupKey, in ordinals: inout [GroupKey: Int]) -> Int {
        if let ordinal = ordinals[key] { return ordinal }
        let ordinal = ordinals.count
        ordinals[key] = ordinal
        return ordinal
    }
}
