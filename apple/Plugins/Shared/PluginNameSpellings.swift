import Foundation
import TableProPluginKit

// A server keeps apart names Swift's String equates (NFC and NFD spellings), so a read keyed by String throws on an
// answer that names one object in two spellings rather than merge the two.
nonisolated enum PluginNameSpellings {
    static func requireDistinctSpellings(
        _ names: some Sequence<String>,
        failure: (String) -> any Error = { PluginNameSpellingError(name: $0) }
    ) throws {
        var seen = Set<String>()
        for name in names {
            let (inserted, known) = seen.insert(name)
            if !inserted, !known.utf8.elementsEqual(name.utf8) {
                throw failure(name)
            }
        }
    }

    static func requireDistinctSpellings(in rows: [[PluginCellValue]], nameAt column: Int) throws {
        try requireDistinctSpellings(rows.lazy.compactMap { $0[safe: column]?.asText })
    }

    // The table-by-table read PluginKit's default makes, for a driver with no schema-wide one.
    static func readEachTable<Value>(
        _ tables: [String],
        read: (String) async throws -> [Value]
    ) async throws -> [String: [Value]] {
        try requireDistinctSpellings(tables)
        var answer: [String: [Value]] = [:]
        for table in tables {
            try Task.checkCancellation()
            let values = try await read(table)
            if !values.isEmpty { answer[table] = values }
        }
        return answer
    }
}

nonisolated struct PluginNameSpellingError: PluginDriverError {
    let name: String

    var pluginErrorMessage: String {
        "Two objects share the name \(name) in different Unicode forms"
    }
}
