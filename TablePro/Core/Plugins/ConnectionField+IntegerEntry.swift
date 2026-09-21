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
