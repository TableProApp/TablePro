//
//  RowGenerationValidation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct RowGenerationIssue: Identifiable, Equatable, Sendable {
    internal let column: String?
    internal let message: String

    internal var id: String { "\(column ?? "")\u{1F}\(message)" }
}

internal enum RowGenerationValidation {
    internal static let scaleRange = 0...10

    internal static func decimalLimit(precision: Int?, scale: Int?) -> Double {
        guard let precision else { return 1e15 }
        let fraction = max(0, scale ?? 0)
        let digits = max(0, precision - fraction)
        return pow(10, Double(digits)) - pow(10, -Double(fraction))
    }

    internal static func issues(
        for settings: RowGenerationSettings,
        in table: RowGenerationTable,
        calendar: Calendar = .current
    ) -> [RowGenerationIssue] {
        var issues: [RowGenerationIssue] = []
        if settings.rowCount < 1 || settings.rowCount > RowGenerationSettings.maximumRowCount {
            issues.append(RowGenerationIssue(
                column: nil,
                message: String(
                    format: String(localized: "Enter a number of rows from 1 to %@."),
                    RowGenerationSettings.maximumRowCount.formatted(.number.grouping(.automatic))
                )
            ))
        }
        var writesAnyColumn = false
        for column in table.columns {
            guard let columnSettings = settings.columns[column.name] else { continue }
            if columnSettings.kind != .serverDefault { writesAnyColumn = true }
            issues += columnIssues(column, columnSettings, rowCount: settings.rowCount, table: table, calendar: calendar)
        }
        if !writesAnyColumn {
            issues.append(RowGenerationIssue(
                column: nil, message: String(localized: "Choose a generator for at least one column.")
            ))
        }
        issues += groupIssues(settings: settings, table: table, calendar: calendar)
        return issues
    }

    // How many different values the generator can make, or nil when that is effectively unlimited.
    internal static func domainSize(
        of settings: RowGeneratorSettings,
        for column: RowGenerationColumn,
        in table: RowGenerationTable,
        calendar: Calendar = .current
    ) -> Int64? {
        switch settings.kind {
        case .integerRange:
            guard settings.integerMinimum <= settings.integerMaximum else { return 0 }
            let span = settings.integerMaximum.subtractingReportingOverflow(settings.integerMinimum)
            return span.overflow || span.partialValue == .max ? nil : span.partialValue + 1
        case .decimalRange:
            guard settings.decimalMinimum <= settings.decimalMaximum else { return 0 }
            let low = RowGenerationValueText.steps(of: settings.decimalMinimum, scale: settings.decimalScale)
            let high = RowGenerationValueText.steps(of: settings.decimalMaximum, scale: settings.decimalScale)
            let span = high.subtractingReportingOverflow(low)
            guard !span.overflow, span.partialValue < .max else { return nil }
            return span.partialValue + 1
        case .list:
            return Int64(Set(settings.values.filter { !$0.isEmpty }).count)
        case .reference:
            guard let slot = column.reference, let source = table.reference(id: slot.sourceId) else { return 0 }
            return Int64(Set(source.tuples.map { $0.indices.contains(slot.position) ? $0[slot.position] : .null }).count)
        case .boolean:
            return 2
        case .date:
            return dayCount(settings, calendar: calendar)
        case .dateTime:
            return dayCount(settings, calendar: calendar).map { $0 * RowGenerationValueText.secondsPerDay }
        case .time:
            return RowGenerationValueText.secondsPerDay
        case .pattern:
            return RowGenerationPattern.combinations(settings.pattern, length: column.maxLength)
        case .serverDefault, .sequence, .text, .firstName, .lastName, .fullName, .email, .phone, .streetAddress,
             .city, .country, .uuid, .json:
            return nil
        }
    }

    private static func dayCount(_ settings: RowGeneratorSettings, calendar: Calendar) -> Int64? {
        let start = RowGenerationValueText.dayNumber(of: settings.dateStart, calendar: calendar)
        let end = RowGenerationValueText.dayNumber(of: settings.dateEnd, calendar: calendar)
        return end >= start ? end - start + 1 : 0
    }

    private static func columnIssues(
        _ column: RowGenerationColumn,
        _ settings: RowGeneratorSettings,
        rowCount: Int,
        table: RowGenerationTable,
        calendar: Calendar
    ) -> [RowGenerationIssue] {
        let name = column.name
        func issue(_ message: String) -> [RowGenerationIssue] { [RowGenerationIssue(column: name, message: message)] }

        let kinds = column.availableKinds
        guard !kinds.isEmpty else {
            return issue(String(
                format: String(localized: "No generator can fill %@ (%@), and it cannot be left empty."),
                name, column.typeName
            ))
        }
        guard kinds.contains(settings.kind) else {
            return issue(String(format: String(localized: "%@ cannot use this generator."), name))
        }
        if let message = rangeIssue(column, settings, rowCount: rowCount, table: table, calendar: calendar) {
            return issue(message)
        }
        if column.isUnique, let size = domainSize(of: settings, for: column, in: table, calendar: calendar),
           size < Int64(rowCount) {
            return issue(String(
                format: String(localized: "%1$@ must not repeat, but its generator makes only %2$@ different values."),
                name, size.formatted(.number.grouping(.automatic))
            ))
        }
        return []
    }

    private static func rangeIssue(
        _ column: RowGenerationColumn,
        _ settings: RowGeneratorSettings,
        rowCount: Int,
        table: RowGenerationTable,
        calendar: Calendar
    ) -> String? {
        let name = column.name
        switch settings.kind {
        case .integerRange:
            guard settings.integerMinimum <= settings.integerMaximum else {
                return String(format: String(localized: "%@: the minimum is larger than the maximum."), name)
            }
            return integerBoundsIssue(column, low: settings.integerMinimum, high: settings.integerMaximum)
        case .sequence:
            guard settings.sequenceStep != 0 else {
                return String(format: String(localized: "%@: the step cannot be 0."), name)
            }
            let span = settings.sequenceStep.multipliedReportingOverflow(by: Int64(max(0, rowCount - 1)))
            let last = settings.integerMinimum.addingReportingOverflow(span.partialValue)
            guard !span.overflow, !last.overflow else {
                return String(format: String(localized: "The sequence for %@ runs past the largest number it can hold."), name)
            }
            return integerBoundsIssue(
                column,
                low: min(settings.integerMinimum, last.partialValue),
                high: max(settings.integerMinimum, last.partialValue)
            )
        case .decimalRange:
            guard RowGenerationValidation.scaleRange.contains(settings.decimalScale) else {
                return String(format: String(localized: "%@: decimal places run from 0 to 10."), name)
            }
            guard settings.decimalMinimum <= settings.decimalMaximum else {
                return String(format: String(localized: "%@: the minimum is larger than the maximum."), name)
            }
            // Values are counted in steps of the last decimal place, which have to fit a 64-bit integer.
            let stepLimit = pow(10, Double(18 - settings.decimalScale))
            guard abs(settings.decimalMinimum) < stepLimit, abs(settings.decimalMaximum) < stepLimit else {
                return String(format: String(localized: "%@: the range is too wide for that many decimal places."), name)
            }
            if case .decimal(let precision, let scale) = column.valueClass {
                // A value with more places than the column keeps is rounded on the way in, and can then repeat.
                if let scale, settings.decimalScale > scale {
                    return String(
                        format: String(localized: "%1$@ keeps %2$@ decimal places."), name, String(scale)
                    )
                }
                let limit = decimalLimit(precision: precision, scale: scale)
                if abs(settings.decimalMinimum) > limit || abs(settings.decimalMaximum) > limit {
                    return String(
                        format: String(localized: "%1$@ holds values up to %2$@."),
                        name, limit.formatted(.number.grouping(.automatic))
                    )
                }
            }
            return nil
        case .text:
            guard settings.minLength >= 0, settings.minLength <= settings.maxLength else {
                return String(format: String(localized: "%@: the shortest length is longer than the longest."), name)
            }
            return nil
        case .date, .dateTime:
            guard dayCount(settings, calendar: calendar) ?? 0 > 0 else {
                return String(format: String(localized: "%@: the first date is after the last."), name)
            }
            return nil
        case .list:
            let values = settings.values.filter { !$0.isEmpty }
            return values.isEmpty ? String(format: String(localized: "Enter at least one value for %@."), name) : nil
        case .pattern:
            return settings.pattern.isEmpty ? String(format: String(localized: "Enter a pattern for %@."), name) : nil
        case .reference:
            guard let slot = column.reference, let source = table.reference(id: slot.sourceId) else { return nil }
            guard source.tuples.isEmpty, !column.isNullable else { return nil }
            return String(
                format: String(localized: "%1$@ references %2$@, which has no rows."), name, source.referencedTable
            )
        default:
            return nil
        }
    }

    private static func integerBoundsIssue(_ column: RowGenerationColumn, low: Int64, high: Int64) -> String? {
        guard case .integer(let minimum, let maximum) = column.valueClass else { return nil }
        guard low < minimum || high > maximum else { return nil }
        return String(
            format: String(localized: "%1$@ holds numbers from %2$@ to %3$@."),
            column.name,
            minimum.formatted(.number.grouping(.automatic)),
            maximum.formatted(.number.grouping(.automatic))
        )
    }

    private static func groupIssues(
        settings: RowGenerationSettings,
        table: RowGenerationTable,
        calendar: Calendar
    ) -> [RowGenerationIssue] {
        table.uniqueGroups.compactMap { group -> RowGenerationIssue? in
            var combinations: Int64 = 1
            var writesMember = false
            for name in group {
                guard let column = table.column(named: name), let columnSettings = settings.columns[name] else {
                    return nil
                }
                // A column that never repeats, or one the server numbers, already keeps the whole key unique.
                if column.isUnique || columnSettings.kind == .sequence { return nil }
                if columnSettings.kind == .serverDefault {
                    if column.ownership == .assigned { return nil }
                    // Any other default is the same in every row, so the rest of the key carries it.
                    continue
                }
                writesMember = true
                guard let size = domainSize(of: columnSettings, for: column, in: table, calendar: calendar) else {
                    return nil
                }
                let product = combinations.multipliedReportingOverflow(by: size)
                guard !product.overflow else { return nil }
                combinations = product.partialValue
            }
            if !writesMember, settings.rowCount > 1 {
                return RowGenerationIssue(
                    column: nil,
                    message: String(
                        format: String(localized: "(%@) must not repeat, but every column of it is left to its default."),
                        group.joined(separator: ", ")
                    )
                )
            }
            guard combinations < Int64(settings.rowCount) else { return nil }
            return RowGenerationIssue(
                column: nil,
                message: String(
                    format: String(localized: "(%1$@) must not repeat, but the generators make only %2$@ combinations."),
                    group.joined(separator: ", "),
                    combinations.formatted(.number.grouping(.automatic))
                )
            )
        }
    }
}
