import Foundation
import TableProPluginKit

// A fake catalog connection: answers each statement from `answer` and keeps what was sent, in order.
final class CatalogReadRecorder: @unchecked Sendable {
    struct Read: Equatable {
        let statement: String
        let namesRelativeTo: String?
    }

    private let lock = NSLock()
    private var recorded: [Read] = []
    private let answer: @Sendable (String) throws -> [[PluginCellValue]]

    init(answer: @escaping @Sendable (String) throws -> [[PluginCellValue]] = { _ in [] }) {
        self.answer = answer
    }

    var reads: [Read] {
        lock.withLock { recorded }
    }

    var statements: [String] {
        reads.map(\.statement)
    }

    var postgreSQLRead: PostgreSQLCatalogExport.Read {
        { [self] statement, schema in try respond(statement, namesRelativeTo: schema) }
    }

    var redshiftRead: RedshiftCatalogExport.Read {
        { [self] statement in try respond(statement, namesRelativeTo: nil) }
    }

    private func respond(_ statement: String, namesRelativeTo schema: String?) throws -> [[PluginCellValue]] {
        lock.withLock { recorded.append(Read(statement: statement, namesRelativeTo: schema)) }
        return try answer(statement)
    }
}

extension Array where Element == String? {
    var cells: [PluginCellValue] {
        map { $0.map(PluginCellValue.text) ?? .null }
    }
}
