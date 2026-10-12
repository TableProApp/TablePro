//
//  DataTableScope.swift
//  TablePro
//

import Foundation

internal struct DataTableScope: Codable, Hashable, Sendable {
    internal var keyColumns: [String]
    internal private(set) var excludedColumns: Set<String>
    internal var sourceFilter: String
    internal var targetFilter: String?
    internal private(set) var rowLimit: Int?

    internal init(
        keyColumns: [String] = [],
        excludedColumns: Set<String> = [],
        sourceFilter: String = "",
        targetFilter: String? = nil,
        rowLimit: Int? = nil
    ) {
        self.keyColumns = keyColumns
        self.excludedColumns = Set(excludedColumns.map { $0.lowercased() })
        self.sourceFilter = sourceFilter
        self.targetFilter = targetFilter
        self.rowLimit = rowLimit.map { max(1, $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case keyColumns
        case excludedColumns
        case sourceFilter
        case targetFilter
        case rowLimit
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyColumns: try container.decodeIfPresent([String].self, forKey: .keyColumns) ?? [],
            excludedColumns: try container.decodeIfPresent(Set<String>.self, forKey: .excludedColumns) ?? [],
            sourceFilter: try container.decodeIfPresent(String.self, forKey: .sourceFilter) ?? "",
            targetFilter: try container.decodeIfPresent(String.self, forKey: .targetFilter),
            rowLimit: try container.decodeIfPresent(Int.self, forKey: .rowLimit)
        )
    }

    internal var usesSameFilterForTarget: Bool {
        targetFilter == nil
    }

    internal var effectiveSourceFilter: String? {
        CompareRowFilter.normalized(sourceFilter)
    }

    internal var effectiveTargetFilter: String? {
        CompareRowFilter.normalized(targetFilter ?? sourceFilter)
    }

    internal var hasFilter: Bool {
        effectiveSourceFilter != nil || effectiveTargetFilter != nil
    }

    internal var filterValidationError: String? {
        if let error = CompareRowFilter.validationError(for: sourceFilter) {
            return error
        }
        guard let targetFilter else { return nil }
        return CompareRowFilter.validationError(for: targetFilter)
    }

    internal func isKeyColumn(_ column: String) -> Bool {
        keyColumns.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
    }

    internal func isExcluded(_ column: String) -> Bool {
        excludedColumns.contains(column.lowercased())
    }

    internal mutating func setExcluded(_ excluded: Bool, column: String) {
        if excluded {
            excludedColumns.insert(column.lowercased())
        } else {
            excludedColumns.remove(column.lowercased())
        }
    }

    internal mutating func restrictExclusions(to columns: [String]) {
        let available = Set(columns.map { $0.lowercased() })
        excludedColumns = excludedColumns.intersection(available)
    }

    internal mutating func setRowLimit(_ limit: Int?) {
        rowLimit = limit.map { max(1, $0) }
    }
}
