import Foundation

public struct CSVTypeInferrer {
    public typealias InferredType = InspectorColumnType

    public static let sampleSize = 200

    private static let booleanLiterals: Set<String> = [
        "true", "false", "yes", "no", "t", "f", "y", "n"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    public static func infer(column values: [String]) -> InferredType {
        var sample: [String] = []
        sample.reserveCapacity(min(values.count, sampleSize))
        for value in values where !value.isEmpty {
            sample.append(value)
            if sample.count >= sampleSize { break }
        }
        guard !sample.isEmpty else { return .text }

        if sample.allSatisfy({ Int($0) != nil }) { return .integer }
        if sample.allSatisfy({ Double($0) != nil }) { return .real }
        if sample.allSatisfy({ booleanLiterals.contains($0.lowercased()) }) { return .boolean }
        if sample.allSatisfy({ isDate($0) }) { return .date }
        return .text
    }

    public static func inferColumns(rows: [[String]], columnCount: Int) -> [InferredType] {
        var result: [InferredType] = []
        result.reserveCapacity(columnCount)
        for col in 0..<columnCount {
            var columnSample: [String] = []
            columnSample.reserveCapacity(min(rows.count, sampleSize))
            for row in rows where col < row.count {
                columnSample.append(row[col])
                if columnSample.count >= sampleSize { break }
            }
            result.append(infer(column: columnSample))
        }
        return result
    }

    private static func isDate(_ value: String) -> Bool {
        if isoFormatter.date(from: value) != nil { return true }
        if dateOnlyFormatter.date(from: value) != nil { return true }
        return false
    }
}
