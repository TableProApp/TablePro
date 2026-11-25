import Foundation

public enum SQLCompletionValueLabels {
    // A list column carries its elements' labels (PostgreSQL ENUM[], DuckDB ENUM('a')[]), and none of them equals it.
    public static func values(_ labels: [String]?, ofColumnType typeName: String) -> [String]? {
        guard let labels, !labels.isEmpty, !typeName.hasSuffix("]") else { return nil }
        return labels
    }
}
