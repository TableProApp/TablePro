//
//  StructureMappingCoverage.swift
//  TableProTests
//
//  Checks a field-for-field mapping against the stored properties of both types, read by reflection,
//  so the check cannot go stale the way a hand-written field list does.
//

import Foundation

enum StructureMappingCoverage {
    /// What makes a set of fixtures unable to catch a broken mapper.
    ///
    /// A field every fixture leaves at one value passes a mapper that drops it. Two fields holding the
    /// same value in one fixture pass a mapper that swaps them. Bool fields have only two values, so
    /// swaps between them are caught only when each has its own pattern across the fixtures, which
    /// takes at least three fixtures once a type has three Bool fields.
    static func fixtureProblems<Source>(_ fixtures: [Source]) -> [String] {
        let fields = fixtures.map { MirroredFields($0) }
        guard fields.count >= 3, let first = fields.first else {
            return ["\(Source.self) needs at least three fixtures, got \(fields.count)"]
        }
        var problems: [String] = []

        for label in first.labels {
            let values = fields.map { $0.described(label) }
            if Set(values).count == 1 {
                problems.append("Every \(Source.self) fixture leaves \(label) at \(values[0])")
            }
        }

        for (position, fixture) in fields.enumerated() {
            let valueLabels = fixture.labels.filter { !fixture.isBool($0) }
            let byValue = Dictionary(grouping: valueLabels) { fixture.described($0) }
            for (value, labels) in byValue where labels.count > 1 {
                let names = labels.sorted().joined(separator: ", ")
                problems.append("\(Source.self) fixture \(position) gives \(names) the same value \(value)")
            }
        }

        let boolLabels = first.labels.filter { first.isBool($0) }
        let byPattern = Dictionary(grouping: boolLabels) { label in
            fields.map { $0.described(label) }.joined(separator: " ")
        }
        for (pattern, labels) in byPattern where labels.count > 1 {
            let names = labels.sorted().joined(separator: ", ")
            problems.append("\(Source.self) fixtures give \(names) the same pattern \(pattern)")
        }

        return problems.sorted()
    }

    /// Every stored property of `Source` must reach a property of the same name on `Target` with the
    /// same value, and `Target` may hold nothing else except the fields named in `appOnly`.
    static func carryProblems<Source, Target>(
        from sources: [Source],
        to targets: [Target],
        appOnly: Set<String>
    ) -> [String] {
        guard sources.count == targets.count else {
            return ["\(sources.count) \(Source.self) values became \(targets.count) \(Target.self) values"]
        }
        var problems: Set<String> = []

        for (source, target) in zip(sources, targets) {
            let sourceFields = MirroredFields(source)
            let targetFields = MirroredFields(target)
            let sourceLabels = Set(sourceFields.labels)
            let targetLabels = Set(targetFields.labels)

            for label in appOnly.subtracting(targetLabels) {
                problems.insert("\(Target.self) has no \(label) any more, so it should leave appOnly")
            }
            for label in sourceLabels.subtracting(targetLabels) {
                problems.insert("\(Target.self) has no \(label), so \(Source.self).\(label) is dropped")
            }
            for label in targetLabels.subtracting(sourceLabels).subtracting(appOnly) {
                problems.insert("\(Target.self).\(label) has no \(Source.self) field to come from")
            }
            for label in sourceFields.labels where targetLabels.contains(label) {
                let expected = sourceFields.described(label)
                let actual = targetFields.described(label)
                if expected != actual {
                    problems.insert("\(label): \(Source.self) has \(expected), \(Target.self) has \(actual)")
                }
            }
        }

        return problems.sorted()
    }
}

private struct MirroredFields {
    let labels: [String]
    private let values: [String: Any]

    init(_ subject: Any) {
        var labels: [String] = []
        var values: [String: Any] = [:]
        for child in Mirror(reflecting: subject).children {
            guard let label = child.label else { continue }
            labels.append(label)
            values[label] = child.value
        }
        self.labels = labels
        self.values = values
    }

    func described(_ label: String) -> String {
        guard let value = values[label], let unwrapped = Self.unwrapped(value) else { return "nil" }
        return String(describing: unwrapped)
    }

    func isBool(_ label: String) -> Bool {
        guard let value = values[label] else { return false }
        return Self.unwrapped(value) is Bool
    }

    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first else { return nil }
        return unwrapped(wrapped.value)
    }
}
