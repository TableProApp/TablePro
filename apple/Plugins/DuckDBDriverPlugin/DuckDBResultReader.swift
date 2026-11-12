import CDuckDB
import Foundation

// DuckDB spells a value as text only through a query. A streaming result keeps its own connection busy until it ends
// (DUCKDB_ERROR_RESOURCE_IN_USE), so a second connection renders each fetched chunk through a table function.
final class DuckDBResultReader: @unchecked Sendable {
    private let name = "_tablepro_result_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let connection: duckdb_connection
    private let connectionID: idx_t
    private let lock = NSLock()
    private var source: duckdb_result?
    private var pendingChunk: duckdb_data_chunk?

    init(renderConnection connection: duckdb_connection) throws {
        self.connection = connection
        var context: duckdb_client_context?
        duckdb_connection_get_client_context(connection, &context)
        defer { duckdb_destroy_client_context(&context) }
        guard let context else { throw DuckDBPluginError.connectionFailed("Could not identify the DuckDB connection") }
        connectionID = duckdb_client_context_get_connection_id(context)

        var function = duckdb_create_table_function()
        defer { duckdb_destroy_table_function(&function) }
        guard let function else { throw DuckDBPluginError.connectionFailed("Could not create the DuckDB result reader") }
        duckdb_table_function_set_name(function, name)
        duckdb_table_function_set_extra_info(function, Unmanaged.passRetained(self).toOpaque()) { pointer in
            guard let pointer else { return }
            Unmanaged<DuckDBResultReader>.fromOpaque(pointer).release()
        }
        duckdb_table_function_set_bind(function) { info in
            guard let info, let pointer = duckdb_bind_get_extra_info(info) else { return }
            Unmanaged<DuckDBResultReader>.fromOpaque(pointer).takeUnretainedValue().bind(info)
        }
        duckdb_table_function_set_init(function) { info in
            duckdb_init_set_max_threads(info, 1)
        }
        duckdb_table_function_set_function(function) { info, output in
            guard let info, let output, let pointer = duckdb_function_get_extra_info(info) else { return }
            Unmanaged<DuckDBResultReader>.fromOpaque(pointer).takeUnretainedValue().scan(info, into: output)
        }
        guard duckdb_register_table_function(connection, function) == DuckDBSuccess else {
            throw DuckDBPluginError.connectionFailed("Could not register the DuckDB result reader")
        }
    }

    func send(_ sql: String) -> Bool {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        return duckdb_query(connection, sql, &result) == DuckDBSuccess
    }

    func prepareProjection(
        of result: duckdb_result,
        columns: [(name: String, type: DuckDBLogicalType?)]
    ) throws -> duckdb_prepared_statement {
        setSource(result, chunk: nil)
        defer { setSource(nil, chunk: nil) }

        let sql = DuckDBProjectedQuery.build(function: name, columns: columns)
        var statement: duckdb_prepared_statement?
        guard duckdb_prepare(connection, sql, &statement) == DuckDBSuccess, let prepared = statement else {
            let message = statement.flatMap { duckdb_prepare_error($0) }.map { String(cString: $0) }
                ?? "Could not render the DuckDB result"
            duckdb_destroy_prepare(&statement)
            throw DuckDBPluginError.queryFailed(message)
        }
        return prepared
    }

    // The chunk has to outlive the call: the rendered result is materialized before this returns.
    func render(
        _ chunk: duckdb_data_chunk,
        of result: duckdb_result,
        with projection: duckdb_prepared_statement
    ) throws -> duckdb_result {
        // DuckDB binds the function again on every execution, so the result stays readable for its column types.
        setSource(result, chunk: chunk)
        defer { setSource(nil, chunk: nil) }

        var rendered = duckdb_result()
        guard duckdb_execute_prepared(projection, &rendered) == DuckDBSuccess else {
            let message = duckdb_result_error(&rendered).map { String(cString: $0) }
                ?? "Could not render the DuckDB result"
            duckdb_destroy_result(&rendered)
            throw DuckDBPluginError.queryFailed(message)
        }
        return rendered
    }

    private func setSource(_ result: duckdb_result?, chunk: duckdb_data_chunk?) {
        lock.lock()
        source = result
        pendingChunk = chunk
        lock.unlock()
    }

    private func bind(_ info: duckdb_bind_info) {
        var context: duckdb_client_context?
        duckdb_table_function_get_client_context(info, &context)
        defer { duckdb_destroy_client_context(&context) }
        guard let context, duckdb_client_context_get_connection_id(context) == connectionID else {
            duckdb_bind_set_error(info, "The result belongs to another connection")
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard var source else {
            duckdb_bind_set_error(info, "No result is being read")
            return
        }
        for column in 0..<duckdb_column_count(&source) {
            var type = duckdb_column_logical_type(&source, column)
            defer { duckdb_destroy_logical_type(&type) }
            guard let type else {
                duckdb_bind_set_error(info, "Could not read a result column type")
                return
            }
            duckdb_bind_add_result_column(info, DuckDBProjectedQuery.sourceAlias(at: Int(column)), type)
        }
    }

    private func scan(_ info: duckdb_function_info, into output: duckdb_data_chunk) {
        lock.lock()
        defer { lock.unlock() }
        guard let chunk = pendingChunk else {
            duckdb_data_chunk_set_size(output, 0)
            return
        }
        pendingChunk = nil
        for column in 0..<duckdb_data_chunk_get_column_count(chunk) {
            duckdb_vector_reference_vector(
                duckdb_data_chunk_get_vector(output, column), duckdb_data_chunk_get_vector(chunk, column)
            )
        }
        duckdb_data_chunk_set_size(output, duckdb_data_chunk_get_size(chunk))
    }
}
