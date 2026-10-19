//
//  ResultChartLabels.swift
//  TablePro
//

import Foundation

internal enum ResultChartLabels {
    /// Numbers every label that occurs more than once, "name (1)", "name (2)", in the order given,
    /// and skips a number whose label is already taken, so a real value spelled "name (1)" cannot
    /// merge with a numbered duplicate.
    static func unique(_ bases: [String]) -> [String] {
        let totals = bases.reduce(into: [String: Int]()) { totals, base in
            totals[base, default: 0] += 1
        }
        var taken = Set(bases)
        var next: [String: Int] = [:]
        return bases.map { base in
            guard totals[base, default: 0] > 1 else { return base }
            var number = next[base, default: 1]
            while taken.contains("\(base) (\(number))") { number += 1 }
            next[base] = number + 1
            let label = "\(base) (\(number))"
            taken.insert(label)
            return label
        }
    }
}
