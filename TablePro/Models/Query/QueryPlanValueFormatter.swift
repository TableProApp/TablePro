//
//  QueryPlanValueFormatter.swift
//  TablePro
//
//  One spelling for every number the comparison draws, so a node row and the summary above it never
//  render the same cost two different ways.
//

import Foundation

enum QueryPlanValueFormatter {
    /// Shown where a plan reports no value at all, as opposed to reporting zero.
    static let absent = "\u{2013}"

    static func string(_ value: QueryPlanFieldValue?, unit: QueryPlanUnit?) -> String {
        guard let value else { return absent }
        switch value {
        case .text(let text):
            return text
        case .number(let number):
            return string(number, unit: unit ?? .cost)
        }
    }

    static func string(_ value: Double, unit: QueryPlanUnit) -> String {
        switch unit {
        case .cost:
            return value.formatted(.number.precision(.fractionLength(0 ... 2)))
        case .count:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .bytes:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .milliseconds:
            return Measurement(value: value, unit: UnitDuration.milliseconds)
                .formatted(.measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0 ... 3))
                ))
        }
    }

    /// The signed difference, with the multiple beside it when there is a baseline to be a multiple
    /// of. Nil when nothing moved, so a caller can draw the row as unchanged rather than as a zero.
    static func change(_ change: QueryPlanFieldChange) -> String? {
        guard change.hasChange else { return nil }
        guard let delta = change.delta, let unit = change.field.unit else {
            return String(localized: "Changed")
        }
        let signed = signedString(delta, unit: unit)
        guard let ratio = change.ratio else { return signed }
        let percent = (ratio - 1).formatted(.percent.precision(.fractionLength(0 ... 1)).sign(strategy: .always()))
        return "\(signed) (\(percent))"
    }

    private static func signedString(_ value: Double, unit: QueryPlanUnit) -> String {
        let magnitude = string(abs(value), unit: unit)
        guard value != 0 else { return magnitude }
        return value > 0 ? "+\(magnitude)" : "\u{2212}\(magnitude)"
    }
}
