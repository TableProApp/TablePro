import Foundation
import TableProDatabase
import TableProModels

extension DuckDBDriver {
    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(escapeLiteral(schemaName))'
            ORDER BY table_name
            """
        let result = try await actor.query(query)
        return result.rows.compactMap { row in
            guard row.count > 0, let name = row[0] else { return nil }
            let typeString = (row.count > 1 ? row[1] : nil) ?? "BASE TABLE"
            let kind: TableInfo.TableKind = typeString.uppercased().contains("VIEW") ? .view : .table
            return TableInfo(name: name, type: kind)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT column_name, data_type, is_nullable, column_default, ordinal_position
            FROM information_schema.columns
            WHERE table_schema = '\(escapeLiteral(schemaName))'
              AND table_name = '\(escapeLiteral(table))'
            ORDER BY ordinal_position
            """
        let result = try await actor.query(query)
        let primaryKeys = try await fetchPrimaryKeyColumns(table: table, schema: schemaName)

        return result.rows.enumerated().compactMap { index, row in
            guard row.count >= 2, let name = row[0], let dataType = row[1] else { return nil }
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: primaryKeys.contains(name),
                isNullable: (row.count > 2 ? row[2] : nil) == "YES",
                defaultValue: row.count > 3 ? row[3] : nil,
                ordinalPosition: index
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT index_name, is_unique, sql
            FROM duckdb_indexes()
            WHERE schema_name = '\(escapeLiteral(schemaName))'
              AND table_name = '\(escapeLiteral(table))'
            """
        let result = try await actor.query(query)
        return result.rows.compactMap { row in
            guard row.count > 0, let name = row[0] else { return nil }
            let sql = row.count > 2 ? row[2] : nil
            let isUnique = (row.count > 1 ? row[1] : nil) == "true"
            let isPrimary = name.lowercased().contains("primary")
                || (sql?.uppercased().contains("PRIMARY KEY") ?? false)
            return IndexInfo(
                name: name,
                columns: Self.extractIndexColumns(from: sql),
                isUnique: isUnique || isPrimary,
                isPrimary: isPrimary,
                type: "ART"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT
                rc.constraint_name,
                kcu.column_name,
                kcu2.table_name AS referenced_table,
                kcu2.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.referential_constraints rc
            JOIN information_schema.key_column_usage kcu
                ON rc.constraint_name = kcu.constraint_name
                AND rc.constraint_schema = kcu.constraint_schema
            JOIN information_schema.key_column_usage kcu2
                ON rc.unique_constraint_name = kcu2.constraint_name
                AND rc.unique_constraint_schema = kcu2.constraint_schema
                AND kcu.ordinal_position = kcu2.ordinal_position
            WHERE kcu.table_schema = '\(escapeLiteral(schemaName))'
              AND kcu.table_name = '\(escapeLiteral(table))'
            """
        do {
            let result = try await actor.query(query)
            return result.rows.compactMap { row in
                guard row.count >= 4,
                      let name = row[0],
                      let column = row[1],
                      let referencedTable = row[2],
                      let referencedColumn = row[3] else {
                    return nil
                }
                return ForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: referencedTable,
                    referencedColumn: referencedColumn,
                    onDelete: (row.count > 4 ? row[4] : nil) ?? "NO ACTION",
                    onUpdate: (row.count > 5 ? row[5] : nil) ?? "NO ACTION"
                )
            }
        } catch {
            return []
        }
    }

    func fetchDatabases() async throws -> [String] { [] }

    func fetchSchemas() async throws -> [String] {
        let query = "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name"
        let result = try await actor.query(query)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        throw DuckDBDriverError.unsupported("DuckDB does not support switching databases on this platform")
    }

    func switchSchema(to name: String) async throws {
        _ = try await actor.query("SET schema = \"\(escapeIdentifier(name))\"")
        setCurrentSchema(name)
    }

    // MARK: - Helpers

    private func fetchPrimaryKeyColumns(table: String, schema: String) async throws -> Set<String> {
        let query = """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
              AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = '\(escapeLiteral(schema))'
              AND tc.table_name = '\(escapeLiteral(table))'
            """
        let result = try await actor.query(query)
        return Set(result.rows.compactMap { $0.first ?? nil })
    }

    private func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private static let indexColumnsRegex = try? NSRegularExpression(
        pattern: #"ON\s+(?:(?:"[^"]*"|[^\s(]+)\s*\.\s*)*(?:"[^"]*"|[^\s(]+)\s*\(([^)]+)\)"#,
        options: .caseInsensitive
    )

    private static func extractIndexColumns(from sql: String?) -> [String] {
        guard let sql, let regex = indexColumnsRegex else { return [] }
        let range = NSRange(sql.startIndex..., in: sql)
        guard let match = regex.firstMatch(in: sql, range: range),
              match.numberOfRanges > 1,
              let columnsRange = Range(match.range(at: 1), in: sql) else {
            return []
        }
        return String(sql[columnsRange]).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        }
    }
}
