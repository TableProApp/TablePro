//
//  ConnectionField+IntegerEntry.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension ConnectionField.IntRange {
    func clamping(_ value: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }

    /// Only a value no further digit can bring back into range is capped while typing. A positive
    /// entry grows with each digit, so one below the lower bound is left alone: forcing a typed
    /// "0" up to 1 on the way to "10" would make that value impossible to enter.
    func fieldText(sanitizing text: String) -> String {
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let isNegative = lowerBound < 0 && scalars.first == "-"
        let digits = String(String.UnicodeScalarView(scalars.filter { ("0"..."9").contains($0) }))
        guard !digits.isEmpty else { return isNegative ? "-" : "" }
        guard let magnitude = Int(digits) else {
            return String(isNegative ? lowerBound : upperBound)
        }
        return isNegative ? String(max(-magnitude, lowerBound)) : String(min(magnitude, upperBound))
    }

    /// An empty field is saved empty, and every driver reads that as the field's default, so the
    /// stepper steps from the default rather than from the lower bound.
    func stepperValue(fromFieldText text: String, defaultValue: String?) -> Int {
        let emptyValue = Int(fieldText(sanitizing: defaultValue ?? "")) ?? lowerBound
        return clamping(Int(fieldText(sanitizing: text)) ?? emptyValue)
    }
}

extension ConnectionField {
    /// A stepper field keeps the text as typed so a value can be entered digit by digit, which
    /// leaves one below the range possible when the user stops typing. Saving it would hand the
    /// driver a number the field says it never accepts.
    func rangeIssue(in value: String) -> String? {
        guard case .stepper(let range) = fieldType,
              let number = Int(value.trimmingCharacters(in: .whitespaces)),
              range.clamping(number) != number else { return nil }
        return String(
            format: String(localized: "%1$@ must be between %2$lld and %3$lld"),
            label, range.lowerBound, range.upperBound
        )
    }
}
