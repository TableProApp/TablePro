//
//  SQLCompletionItem.swift
//  TablePro
//
//  Model for SQL autocomplete suggestions
//

import AppKit
import Foundation

/// Category of completion item
enum SQLCompletionKind: String, CaseIterable {
    case keyword    // SELECT, FROM, WHERE, etc.
    case table      // Database tables
    case view       // Database views
    case column     // Table columns
    case function   // SQL functions (COUNT, SUM, NOW, etc.)
    case schema     // Database/schema names
    case alias      // Table aliases
    case `operator` // Operators (=, <>, LIKE, etc.)
    case favorite   // Saved SQL favorite (keyword expansion)

    /// SF Symbol for display
    var iconName: String {
        switch self {
        case .keyword: return "k.circle.fill"
        case .table: return "t.circle.fill"
        case .view: return "v.circle.fill"
        case .column: return "c.circle.fill"
        case .function: return "f.circle.fill"
        case .schema: return "s.circle.fill"
        case .alias: return "a.circle.fill"
        case .operator: return "equal.circle.fill"
        case .favorite: return "star.circle.fill"
        }
    }

    /// Color for the icon
    var iconColor: NSColor {
        switch self {
        case .keyword: return .systemBlue
        case .table: return .systemTeal
        case .view: return .systemPurple
        case .column: return .systemOrange
        case .function: return .systemPink
        case .schema: return .systemGreen
        case .alias: return .systemGray
        case .operator: return .systemIndigo
        case .favorite: return .systemYellow
        }
    }

    /// Base sort priority (lower = higher priority in same context)
    var basePriority: Int {
        switch self {
        case .favorite: return 50
        case .column: return 100
        case .table: return 200
        case .view: return 210
        case .function: return 300
        case .keyword: return 400
        case .alias: return 150
        case .schema: return 500
        case .operator: return 350
        }
    }
}

/// A single completion suggestion
struct SQLCompletionItem: Identifiable, Hashable {
    let id: UUID
    let label: String           // Display text
    let kind: SQLCompletionKind
    let insertText: String      // Text to insert (may differ from label)
    let detail: String?         // Type info, e.g., "VARCHAR(255)"
    let documentation: String?  // Tooltip/description
    var sortPriority: Int       // For ranking (lower = higher priority)
    let filterText: String      // Text used for matching

    init(
        label: String,
        kind: SQLCompletionKind,
        insertText: String? = nil,
        detail: String? = nil,
        documentation: String? = nil,
        sortPriority: Int? = nil,
        filterText: String? = nil
    ) {
        self.id = UUID()
        self.label = label
        self.kind = kind
        self.insertText = insertText ?? label
        self.detail = detail
        self.documentation = documentation
        self.sortPriority = sortPriority ?? kind.basePriority
        self.filterText = filterText ?? label.lowercased()
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(kind)
    }

    static func == (lhs: SQLCompletionItem, rhs: SQLCompletionItem) -> Bool {
        lhs.label == rhs.label && lhs.kind == rhs.kind
    }
}

// MARK: - Factory Methods

extension SQLCompletionItem {
    /// Documentation for common SQL keywords
    private static let keywordDocs: [String: String] = [
        "SELECT": "Retrieve data from one or more tables",
        "FROM": "Specify tables to query data from",
        "WHERE": "Filter rows based on conditions",
        "JOIN": "Combine rows from two or more tables",
        "LEFT JOIN": "Return all rows from left table with matching rows from right",
        "RIGHT JOIN": "Return all rows from right table with matching rows from left",
        "INNER JOIN": "Return rows with matches in both tables",
        "FULL JOIN": "Return all rows when there is a match in either table",
        "CROSS JOIN": "Return Cartesian product of both tables",
        "INSERT": "Add new rows to a table",
        "UPDATE": "Modify existing rows in a table",
        "DELETE": "Remove rows from a table",
        "CREATE": "Create database objects (tables, views, indexes)",
        "ALTER": "Modify database object structure",
        "DROP": "Remove database objects",
        "GROUP BY": "Group rows by column values",
        "ORDER BY": "Sort result set by columns",
        "HAVING": "Filter groups based on conditions",
        "LIMIT": "Restrict number of returned rows",
        "OFFSET": "Skip a number of rows before returning results",
        "DISTINCT": "Return only unique rows",
        "UNION": "Combine results of multiple SELECT statements",
        "INTERSECT": "Return rows common to multiple SELECT statements",
        "EXCEPT": "Return rows from first SELECT not in second",
        "AND": "Combine conditions (all must be true)",
        "OR": "Combine conditions (any must be true)",
        "NOT": "Negate a condition",
        "AS": "Create an alias for a table or column",
        "IN": "Match against a list of values",
        "BETWEEN": "Match values within a range",
        "LIKE": "Pattern matching with wildcards",
        "ILIKE": "Case-insensitive pattern matching (PostgreSQL)",
        "IS NULL": "Check for null values",
        "IS NOT NULL": "Check for non-null values",
        "EXISTS": "Check if subquery returns rows",
        "NOT EXISTS": "Check if subquery returns no rows",
        "CASE": "Conditional expression",
        "WHEN": "Specify condition in CASE expression",
        "THEN": "Specify result for CASE condition",
        "ELSE": "Default result in CASE expression",
        "END": "End CASE expression",
        "RETURNING": "Return affected rows (PostgreSQL)",
        "WITH": "Define common table expressions (CTEs)",
        "VALUES": "Specify row data for INSERT",
        "SET": "Assign values to columns in UPDATE",
        "ON": "Specify join condition",
        "USING": "Specify join columns with matching names",
        "ASC": "Sort in ascending order",
        "DESC": "Sort in descending order",
        "NULL": "Represents a missing or unknown value",
        "DEFAULT": "Use column default value",
        "TRUE": "Boolean true value",
        "FALSE": "Boolean false value",
        "PRIMARY KEY": "Uniquely identifies each row in a table",
        "FOREIGN KEY": "References a primary key in another table",
        "REFERENCES": "Define foreign key reference to another table",
        "UNIQUE": "Ensure all values in a column are distinct",
        "CHECK": "Ensure values satisfy a condition",
        "CONSTRAINT": "Define a named table constraint",
        "INDEX": "Create an index for faster lookups",
        "CASCADE": "Propagate action to dependent rows",
        "RESTRICT": "Prevent action if dependent rows exist",
        "IF NOT EXISTS": "Only execute if object does not already exist",
        "IF EXISTS": "Only execute if object exists",
        "ON DELETE": "Action when referenced row is deleted",
        "ON UPDATE": "Action when referenced row is updated",
        "ENGINE": "Specify storage engine (MySQL)",
        "AUTO_INCREMENT": "Auto-generate sequential values",
        "PARTITION BY": "Divide window into partitions",
        "NULLS FIRST": "Sort null values before non-null values",
        "NULLS LAST": "Sort null values after non-null values",
        "ON CONFLICT": "Handle unique constraint violations (PostgreSQL)",
        "ON DUPLICATE KEY UPDATE": "Handle duplicate key on insert (MySQL)",
    ]

    /// Create a keyword completion item
    static func keyword(_ keyword: String, documentation: String? = nil) -> SQLCompletionItem {
        let doc = documentation ?? keywordDocs[keyword.uppercased()]
        return SQLCompletionItem(
            label: keyword.uppercased(),
            kind: .keyword,
            insertText: keyword.uppercased(),
            documentation: doc
        )
    }

    /// Create a table completion item
    static func table(_ name: String, isView: Bool = false) -> SQLCompletionItem {
        SQLCompletionItem(
            label: name,
            kind: isView ? .view : .table,
            insertText: name,
            detail: isView ? "View" : "Table"
        )
    }

    /// Create a column completion item
    static func column(
        _ name: String,
        dataType: String?,
        tableName: String? = nil,
        isPrimaryKey: Bool = false,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        comment: String? = nil
    ) -> SQLCompletionItem {
        // Build detail string: "PK · NOT NULL · INT"
        var detailParts: [String] = []
        if isPrimaryKey { detailParts.append("PK") }
        if !isNullable { detailParts.append("NOT NULL") }
        if let dataType { detailParts.append(dataType) }
        let detail = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")

        // Build documentation
        var docParts: [String] = []
        if let tableName { docParts.append("Column from \(tableName)") }
        if let defaultValue { docParts.append("Default: \(defaultValue)") }
        if let comment { docParts.append(comment) }
        let documentation = docParts.isEmpty ? nil : docParts.joined(separator: "\n")

        return SQLCompletionItem(
            label: name,
            kind: .column,
            insertText: name,
            detail: detail,
            documentation: documentation
        )
    }

    /// Create a function completion item
    static func function(_ name: String, signature: String? = nil, documentation: String? = nil) -> SQLCompletionItem {
        let insertText = signature != nil ? "\(name)()" : name
        return SQLCompletionItem(
            label: name,
            kind: .function,
            insertText: insertText,
            detail: signature,
            documentation: documentation
        )
    }

    /// Create an operator completion item
    static func `operator`(_ op: String, documentation: String? = nil) -> SQLCompletionItem {
        SQLCompletionItem(
            label: op,
            kind: .operator,
            insertText: op,
            documentation: documentation
        )
    }

    /// Create a favorite keyword expansion item
    static func favorite(keyword: String, name: String, query: String) -> SQLCompletionItem {
        SQLCompletionItem(
            label: keyword,
            kind: .favorite,
            insertText: query,
            detail: name,
            documentation: String(query.prefix(200))
        )
    }
}
