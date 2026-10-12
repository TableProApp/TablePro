import Foundation
import TableProTabularIO

public struct TabularJSONLiteralError: Error, Equatable, Sendable {
    public let key: Int
    public let column: TabularColumnID
    public let underlying: JSONValueTypingError

    public init(key: Int, column: TabularColumnID, underlying: JSONValueTypingError) {
        self.key = key
        self.column = column
        self.underlying = underlying
    }
}

public extension TabularTable {
    func jsonKeyChanges(sourceKeys: [String]) -> [String: JSONMemberChange] {
        var changes: [String: JSONMemberChange] = [:]
        let present = Dictionary(uniqueKeysWithValues: columns.map { ($0.id.rawValue, $0) })
        for (index, key) in sourceKeys.enumerated() {
            guard let column = present[index] else {
                changes[key] = .remove
                continue
            }
            if column.name != key {
                changes[key] = .rename(to: column.name)
            }
        }
        return changes
    }

    func jsonOutputRows(
        sourceKeys: [String]?,
        literal: @escaping (TabularCell, TabularColumnID) throws -> String
    ) -> TabularJSONOutputRows {
        TabularJSONOutputRows(table: self, sourceKeys: sourceKeys, literal: literal)
    }
}

public struct TabularJSONOutputRows: Sequence {
    public final class Status {
        public fileprivate(set) var failure: TabularJSONLiteralError?
    }

    public let table: TabularTable
    public let sourceKeys: [String]?
    public let literal: (TabularCell, TabularColumnID) throws -> String
    public let status = Status()

    init(table: TabularTable, sourceKeys: [String]?, literal: @escaping (TabularCell, TabularColumnID) throws -> String) {
        self.table = table
        self.sourceKeys = sourceKeys
        self.literal = literal
    }

    public func makeIterator() -> Iterator {
        Iterator(rows: self)
    }

    public struct Iterator: IteratorProtocol {
        private let rows: TabularJSONOutputRows
        private let sourceColumns: [(column: TabularColumn, key: String)]
        private let addedColumns: [TabularColumn]
        private var position = 0

        init(rows: TabularJSONOutputRows) {
            self.rows = rows
            guard let keys = rows.sourceKeys else {
                sourceColumns = []
                addedColumns = rows.table.columns
                return
            }
            var mapped: [(column: TabularColumn, key: String)] = []
            var added: [TabularColumn] = []
            for column in rows.table.columns {
                let index = column.id.rawValue
                if index < keys.count {
                    mapped.append((column, keys[index]))
                } else {
                    added.append(column)
                }
            }
            sourceColumns = mapped
            addedColumns = added
        }

        public mutating func next() -> JSONOutputRow? {
            guard rows.status.failure == nil, position < rows.table.rowCount else { return nil }
            let key = rows.table.key(atRow: position)
            position += 1
            do {
                return try outputRow(forKey: key)
            } catch let error as TabularJSONLiteralError {
                rows.status.failure = error
                return nil
            } catch {
                return nil
            }
        }

        private func outputRow(forKey key: Int) throws -> JSONOutputRow {
            let table = rows.table
            guard rows.sourceKeys != nil, table.isSourceKey(key) else {
                return .new(try members(forKey: key, columns: table.columns))
            }
            var edits: [JSONMemberEdit] = []
            for (column, sourceKey) in sourceColumns where Self.isChanged(column, key: key) {
                let cell = table.cell(key: key, column: column)
                guard cell.kind != .missing else {
                    edits.append(JSONMemberEdit(sourceKey: sourceKey, change: .remove))
                    continue
                }
                edits.append(JSONMemberEdit(
                    sourceKey: sourceKey,
                    change: .replace(with: try literal(cell, column: column, key: key))
                ))
            }
            let appended = try members(forKey: key, columns: addedColumns)
            guard !edits.isEmpty || !appended.isEmpty else { return .source(key) }
            return .edited(key, JSONObjectEdit(edits: edits, appended: appended))
        }

        private func members(forKey key: Int, columns: [TabularColumn]) throws -> [JSONNewMember] {
            var result: [JSONNewMember] = []
            for column in columns {
                let cell = rows.table.cell(key: key, column: column)
                guard cell.kind != .missing else { continue }
                result.append(JSONNewMember(key: column.name, literal: try literal(cell, column: column, key: key)))
            }
            return result
        }

        private func literal(_ cell: TabularCell, column: TabularColumn, key: Int) throws -> String {
            do {
                return try rows.literal(cell, column.id)
            } catch let error as JSONValueTypingError {
                throw TabularJSONLiteralError(key: key, column: column.id, underlying: error)
            }
        }

        private static func isChanged(_ column: TabularColumn, key: Int) -> Bool {
            let values = column.values
            guard case .source(let index) = values.base, index == column.id.rawValue else { return true }
            return values.edits[key] != nil || values.patch.slot(forKey: key) != nil
        }
    }
}
