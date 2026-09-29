import Foundation
import TableProPluginKit

enum HanaColumnGeneration: Equatable, Sendable {
    case identity(IdentityKind)
    case computed(GenerationKind)
    case systemTime

    init?(generationType: String?) {
        guard let generationType else { return nil }
        let normalized = generationType
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        switch normalized {
        case "ALWAYS AS IDENTITY":
            self = .identity(.always)
        case "BY DEFAULT AS IDENTITY":
            self = .identity(.byDefault)
        case "ALWAYS AS":
            self = .computed(.stored)
        case "ALWAYS CALCULATED AS":
            self = .computed(.virtual)
        default:
            guard normalized.contains("ROW START") || normalized.contains("ROW END") else { return nil }
            self = .systemTime
        }
    }
}

struct HanaCatalogColumn: Equatable, Sendable {
    let table: String
    let name: String
    let typeName: String
    let length: Int?
    let scale: Int?
    let isNullable: Bool
    let defaultValue: String?
    let comment: String?
    let generation: HanaColumnGeneration?
    let generationExpression: String?
    let primaryKeyPosition: Int?

    init(
        table: String,
        name: String,
        typeName: String,
        length: Int? = nil,
        scale: Int? = nil,
        isNullable: Bool = true,
        defaultValue: String? = nil,
        comment: String? = nil,
        generation: HanaColumnGeneration? = nil,
        generationExpression: String? = nil,
        primaryKeyPosition: Int? = nil
    ) {
        self.table = table
        self.name = name
        self.typeName = typeName
        self.length = length
        self.scale = scale
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.comment = comment
        self.generation = generation
        self.generationExpression = generationExpression
        self.primaryKeyPosition = primaryKeyPosition
    }

    init?(row: [PluginCellValue]) {
        guard let table = row[safe: 0]?.asText,
              let name = row[safe: 1]?.asText,
              let typeName = row[safe: 2]?.asText else {
            return nil
        }
        self.init(
            table: table,
            name: name,
            typeName: typeName,
            length: HanaCatalogMapping.integer(row[safe: 3]),
            scale: HanaCatalogMapping.integer(row[safe: 4]),
            isNullable: HanaCatalogMapping.isTrue(row[safe: 5]),
            defaultValue: HanaCatalogMapping.text(row[safe: 6]),
            comment: HanaCatalogMapping.nonEmptyText(row[safe: 7]),
            generation: HanaColumnGeneration(generationType: HanaCatalogMapping.text(row[safe: 8])),
            generationExpression: HanaCatalogMapping.nonEmptyText(row[safe: 9]),
            primaryKeyPosition: HanaCatalogMapping.integer(row[safe: 10])
        )
    }

    var dataType: String {
        HanaCatalogMapping.renderedType(name: typeName, length: length, scale: scale)
    }

    var isPrimaryKey: Bool { primaryKeyPosition != nil }

    var pluginColumn: PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: comment,
            identityKind: identityKind,
            isGenerated: isGenerated,
            allowedValues: nil,
            generationExpression: computedKind == nil ? nil : generationExpression,
            generationKind: computedKind,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: HanaCatalogMapping.classificationTypeName(forTypeName: typeName)
        )
    }

    private var identityKind: IdentityKind? {
        guard case .identity(let kind) = generation else { return nil }
        return kind
    }

    private var computedKind: GenerationKind? {
        guard case .computed(let kind) = generation else { return nil }
        return kind
    }

    private var isGenerated: Bool {
        switch generation {
        case .computed, .systemTime: return true
        case .identity, nil: return false
        }
    }
}

enum HanaCatalogMapping {
    private static let lengthTypes: Set<String> = [
        "CHAR", "NCHAR", "VARCHAR", "NVARCHAR", "ALPHANUM", "SHORTTEXT", "VARBINARY", "BINARY"
    ]

    private static let uniqueConstraints: Set<String> = ["PRIMARY_KEY", "UNIQUE", "NOT_NULL_UNIQUE"]

    private static let quotedDefaultTypes: Set<String> = [
        "CHAR", "NCHAR", "VARCHAR", "NVARCHAR", "ALPHANUM", "SHORTTEXT", "CLOB", "NCLOB", "TEXT", "BINTEXT",
        "DATE", "TIME", "SECONDDATE", "TIMESTAMP"
    ]

    private static let defaultFunctions: Set<String> = [
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_UTCDATE", "CURRENT_UTCTIME",
        "CURRENT_UTCTIMESTAMP", "CURRENT_USER", "SESSION_USER", "CURRENT_SCHEMA"
    ]

    private static let creatableIndexTypes: Set<String> = [
        "BTREE", "CPBTREE", "INVERTED VALUE", "INVERTED HASH", "INVERTED INDIVIDUAL", "FULLTEXT"
    ]

    static func renderedType(name: String, length: Int?, scale: Int?) -> String {
        let upper = name.uppercased()
        if lengthTypes.contains(upper), let length, length > 0 {
            return "\(name)(\(length))"
        }
        if upper == "DECIMAL", let length, let scale {
            return "\(name)(\(length),\(scale))"
        }
        return name
    }

    static func classificationTypeName(forTypeName name: String) -> String? {
        let upper = name.uppercased()
        switch upper {
        case "SECONDDATE": return "TIMESTAMP"
        case "SMALLDECIMAL": return "DECIMAL"
        default: return upper.hasPrefix("ST_") ? "TEXT" : nil
        }
    }

    static func tables(from rows: [[PluginCellValue]], schema: String) -> [PluginTableInfo] {
        rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginTableInfo(
                name: name,
                type: row[safe: 1]?.asText ?? "TABLE",
                schema: schema,
                comment: nonEmptyText(row[safe: 2]),
                partitionCount: nil
            )
        }
    }

    static func columns(from rows: [[PluginCellValue]]) -> [HanaCatalogColumn] {
        rows.compactMap(HanaCatalogColumn.init(row:))
    }

    static func columnsByTable(from rows: [[PluginCellValue]]) -> [String: [PluginColumnInfo]] {
        var grouped: [String: [PluginColumnInfo]] = [:]
        for column in columns(from: rows) {
            grouped[column.table, default: []].append(column.pluginColumn)
        }
        return grouped
    }

    static func indexes(from rows: [[PluginCellValue]]) -> [PluginIndexInfo] {
        var order: [String] = []
        var types: [String: String] = [:]
        var constraints: [String: String] = [:]
        var columns: [String: [String]] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.asText, let column = row[safe: 3]?.asText else { continue }
            if columns[name] == nil {
                order.append(name)
                types[name] = row[safe: 1]?.asText
            }
            if constraints[name] == nil, let constraint = nonEmptyText(row[safe: 2]) {
                constraints[name] = normalizedConstraint(constraint)
            }
            columns[name, default: []].append(column)
        }
        return order.map { name in
            let constraint = constraints[name] ?? ""
            return PluginIndexInfo(
                name: name,
                columns: columns[name] ?? [],
                isUnique: uniqueConstraints.contains(constraint),
                isPrimary: constraint == "PRIMARY_KEY",
                type: types[name] ?? "BTREE",
                columnPrefixes: nil,
                whereClause: nil,
                expressions: nil,
                includedColumns: nil,
                ddlMethodAndKeys: nil,
                ddlWhereClause: nil,
                isValid: nil
            )
        }
    }

    static func foreignKeys(from rows: [[PluginCellValue]]) -> [PluginForeignKeyInfo] {
        rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let column = row[safe: 1]?.asText,
                  let referencedTable = row[safe: 3]?.asText,
                  let referencedColumn = row[safe: 4]?.asText else {
                return nil
            }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn,
                referencedDatabase: nil,
                referencedSchema: nonEmptyText(row[safe: 2]),
                onDelete: nonEmptyText(row[safe: 6]) ?? "RESTRICT",
                onUpdate: nonEmptyText(row[safe: 5]) ?? "RESTRICT"
            )
        }
    }

    static func tableMetadata(table: String, row: [PluginCellValue]) -> PluginTableMetadata {
        let size = integer64(row[safe: 3])
        return PluginTableMetadata(
            tableName: table,
            dataSize: size,
            totalSize: size,
            rowCount: integer64(row[safe: 2]),
            comment: nonEmptyText(row[safe: 1]),
            engine: nonEmptyText(row[safe: 0])
        )
    }

    static func tableDDL(
        schema: String,
        table: String,
        isColumnTable: Bool,
        columns: [HanaCatalogColumn]
    ) -> String {
        var definitions = columns.map { "    \(columnDefinition($0))" }
        let keyColumns = columns
            .compactMap { column in column.primaryKeyPosition.map { (position: $0, name: column.name) } }
            .sorted { $0.position < $1.position }
            .map { HanaSQL.quoteIdentifier($0.name) }
        if !keyColumns.isEmpty {
            definitions.append("    PRIMARY KEY (\(keyColumns.joined(separator: ", ")))")
        }
        let store = isColumnTable ? "COLUMN" : "ROW"
        return "CREATE \(store) TABLE \(HanaSQL.qualifiedName(schema: schema, name: table)) (\n"
            + definitions.joined(separator: ",\n")
            + "\n);"
    }

    static func renderedDefault(_ value: String, typeName: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard quotedDefaultTypes.contains(typeName.uppercased()),
              !trimmed.hasPrefix("'"),
              !trimmed.uppercased().hasPrefix("N'"),
              !defaultFunctions.contains(trimmed.uppercased()) else {
            return value
        }
        return HanaSQL.quoteLiteral(value)
    }

    static func indexStatements(schema: String, table: String, rows: [[PluginCellValue]]) -> [String] {
        var order: [String] = []
        var descriptions: [String: (type: String, constraint: String, keys: [String])] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.asText, let column = row[safe: 3]?.asText else { continue }
            if descriptions[name] == nil {
                order.append(name)
                descriptions[name] = (
                    normalizedIndexType(row[safe: 1]?.asText),
                    nonEmptyText(row[safe: 2]).map(normalizedConstraint) ?? "",
                    []
                )
            }
            let direction = row[safe: 4]?.asText?.uppercased() == "FALSE" ? " DESC" : ""
            descriptions[name]?.keys.append(HanaSQL.quoteIdentifier(column) + direction)
        }
        return order.compactMap { name in
            guard let index = descriptions[name], index.constraint != "PRIMARY_KEY",
                  creatableIndexTypes.contains(index.type) else {
                return nil
            }
            let unique = uniqueConstraints.contains(index.constraint) ? "UNIQUE " : ""
            return "CREATE \(unique)\(index.type) INDEX \(HanaSQL.qualifiedName(schema: schema, name: name)) ON "
                + "\(HanaSQL.qualifiedName(schema: schema, name: table)) (\(index.keys.joined(separator: ", ")));"
        }
    }

    static func commentStatements(
        schema: String,
        table: String,
        relation: [PluginCellValue]?,
        columns: [HanaCatalogColumn]
    ) -> [String] {
        let qualified = HanaSQL.qualifiedName(schema: schema, name: table)
        var statements: [String] = []
        if let kind = relation?[safe: 0]?.asText, let comment = nonEmptyText(relation?[safe: 1]) {
            statements.append("COMMENT ON \(kind) \(qualified) IS \(HanaSQL.quoteLiteral(comment));")
        }
        for column in columns {
            guard let comment = column.comment else { continue }
            let target = "\(qualified).\(HanaSQL.quoteIdentifier(column.name))"
            statements.append("COMMENT ON COLUMN \(target) IS \(HanaSQL.quoteLiteral(comment));")
        }
        return statements
    }

    static func viewDDL(schema: String, view: String, definition: String) -> String {
        "CREATE VIEW \(HanaSQL.qualifiedName(schema: schema, name: view)) AS\n\(definition)"
    }

    static func isTrue(_ cell: PluginCellValue?) -> Bool {
        cell?.asText?.caseInsensitiveCompare("TRUE") == .orderedSame
    }

    static func integer(_ cell: PluginCellValue?) -> Int? {
        cell?.asText.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func integer64(_ cell: PluginCellValue?) -> Int64? {
        cell?.asText.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func text(_ cell: PluginCellValue?) -> String? {
        cell?.asText
    }

    static func nonEmptyText(_ cell: PluginCellValue?) -> String? {
        guard let text = cell?.asText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func normalizedIndexType(_ type: String?) -> String {
        (type ?? "BTREE")
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedConstraint(_ constraint: String) -> String {
        constraint
            .uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
    }

    private static func columnDefinition(_ column: HanaCatalogColumn) -> String {
        var definition = "\(HanaSQL.quoteIdentifier(column.name)) \(column.dataType)"
        switch column.generation {
        case .identity(let kind):
            definition += kind == .always ? " GENERATED ALWAYS AS IDENTITY" : " GENERATED BY DEFAULT AS IDENTITY"
        case .computed(let kind):
            if let expression = column.generationExpression {
                definition += kind == .stored ? " GENERATED ALWAYS AS (\(expression))" : " AS (\(expression))"
            }
        case .systemTime, nil:
            if let defaultValue = column.defaultValue {
                definition += " DEFAULT \(renderedDefault(defaultValue, typeName: column.typeName))"
            }
        }
        if !column.isNullable {
            definition += " NOT NULL"
        }
        return definition
    }
}
