import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    func streamRows(query: String, safeModeIsReadOnly: Bool = false) -> AsyncThrowingStream<PluginStreamElement, Error> {
        if let error = StatementTextValidator.error(for: query) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        noteDatabaseMoves([query])
        return pluginDriver.streamRows(query: query, context: streamContext(query, safeModeIsReadOnly))
    }

    func streamExportRows(
        query: String,
        safeModeIsReadOnly: Bool = false
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        if let error = StatementTextValidator.error(for: query) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        noteDatabaseMoves([query])
        return pluginDriver.streamExportRows(query: query, context: streamContext(query, safeModeIsReadOnly))
    }

    private func streamContext(_ query: String, _ safeModeIsReadOnly: Bool) -> PluginStatementContext {
        var context = statementContext(query)
        context.enforcesReadOnly = readOnlyRunContext(safeModeIsReadOnly: safeModeIsReadOnly) != nil
        context.readFunctionCalls(in: query, databaseType: connection.type)
        return context
    }
}
