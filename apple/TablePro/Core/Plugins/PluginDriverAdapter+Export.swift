import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        if let error = StatementTextValidator.error(for: query) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return schemaPluginDriver.streamRows(query: query, context: statementContext(query))
    }

    func streamExportRows(query: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        if let error = StatementTextValidator.error(for: query) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return schemaPluginDriver.streamExportRows(query: query, context: statementContext(query))
    }
}
