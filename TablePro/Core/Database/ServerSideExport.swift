//
//  ServerSideExport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Unloading a database to somewhere the server can write, rather than to a file on this Mac.
///
/// Oracle Data Pump writes to a `DIRECTORY` object, Snowflake to a stage, BigQuery to a GCS bucket.
/// None of them can hand back a local file, so none of them fit the save panel that every other
/// dump flow ends in. Presenting them there would mean a Save dialog whose file never appears.
///
/// The statement is built here and run through the user's own connection, so it inherits their
/// privileges: an account that may not write to the named destination gets the server's own error,
/// which is a better answer than any check made here.
enum ServerSideExport {
    /// Where the server is being asked to write.
    enum Destination: Equatable {
        /// An Oracle `DIRECTORY` object, named rather than pathed: the path is the server's and
        /// only the DBA who created the directory knows it.
        case oracleDirectory(name: String)
        /// A Snowflake stage reference, including its `@`.
        case snowflakeStage(name: String)
        /// A `gs://` prefix BigQuery writes shards under.
        case googleCloudStorage(uri: String)
    }

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv
        case parquet
        case json

        var id: String { rawValue }

        var label: String {
            switch self {
            case .csv: return "CSV"
            case .parquet: return "Parquet"
            case .json: return "JSON"
            }
        }
    }

    struct Request: Equatable {
        let table: String
        let schema: String?
        let destination: Destination
        let format: Format

        init(table: String, schema: String? = nil, destination: Destination, format: Format) {
            self.table = table
            self.schema = schema
            self.destination = destination
            self.format = format
        }
    }

    /// Snowflake ships as a registry-only plugin and has no `DatabaseType` static of its own.
    /// Matching its raw value here beats adding one, which would put it in `allKnownTypes` and
    /// change what the New Connection picker offers.
    static let snowflake = DatabaseType(rawValue: "Snowflake")

    /// Which engines this offers at all. Everything else has a client-side dump and belongs in
    /// `NativeDumpRegistry` instead.
    static func supports(_ type: DatabaseType) -> Bool {
        type == .oracle || type == snowflake || type == .bigQuery
    }

    static func destinationKinds(for type: DatabaseType) -> [Destination] {
        switch type {
        case .oracle: return [.oracleDirectory(name: "")]
        case .bigQuery: return [.googleCloudStorage(uri: "")]
        default: return type == snowflake ? [.snowflakeStage(name: "")] : []
        }
    }

    static func supportedFormats(for type: DatabaseType) -> [Format] {
        switch type {
        case .oracle: return [.csv]
        case .bigQuery: return [.csv, .parquet, .json]
        default: return type == snowflake ? [.csv, .parquet, .json] : []
        }
    }

    /// The statement the server runs. Nil when the engine and destination do not go together, which
    /// the UI prevents but a caller could still ask for.
    static func statement(
        for request: Request,
        databaseType: DatabaseType,
        quoteIdentifier: (String) -> String,
        escapeLiteral: (String) -> String
    ) -> String? {
        switch request.destination {
        case .oracleDirectory(let directory):
            return oracleStatement(request, directory: directory)
        case .snowflakeStage(let stage):
            return snowflakeStatement(request, stage: stage, quote: quoteIdentifier, escape: escapeLiteral)
        case .googleCloudStorage(let uri):
            return bigQueryStatement(request, uri: uri, quote: quoteIdentifier, escape: escapeLiteral)
        }
    }

    // MARK: - Oracle

    /// Data Pump is a job rather than a statement, and `DBMS_DATAPUMP` is the only way to start one
    /// without shelling out to `expdp` on the server. The file lands in the directory object, so the
    /// caller is told where rather than handed anything.
    private static func oracleStatement(
        _ request: Request,
        directory: String
    ) -> String? {
        guard !directory.isEmpty else { return nil }
        let dumpFile = "\(sanitizedFileStem(request.table)).dmp"
        let logFile = "\(sanitizedFileStem(request.table)).log"
        return """
            DECLARE
              handle NUMBER;
            BEGIN
              handle := DBMS_DATAPUMP.OPEN('EXPORT', 'TABLE', NULL, '\(sanitizedFileStem(request.table))');
              DBMS_DATAPUMP.ADD_FILE(handle, '\(dumpFile)', '\(directory.uppercased())');
              DBMS_DATAPUMP.ADD_FILE(handle, '\(logFile)', '\(directory.uppercased())', NULL,
                DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE);
              DBMS_DATAPUMP.METADATA_FILTER(handle, 'NAME_EXPR', 'IN (''\(request.table.uppercased())'')');
              DBMS_DATAPUMP.METADATA_FILTER(handle, 'SCHEMA_EXPR', 'IN (''\(schemaFilter(request))'')');
              DBMS_DATAPUMP.START_JOB(handle);
              DBMS_DATAPUMP.DETACH(handle);
            END;
            """
    }

    /// Data Pump filters by schema separately from table, so an unqualified request exports from
    /// whatever schema the session is in, which is what `USER` names.
    private static func schemaFilter(_ request: Request) -> String {
        guard let schema = request.schema, !schema.isEmpty else { return "'' || USER || ''" }
        return schema.uppercased()
    }

    // MARK: - Snowflake

    private static func snowflakeStatement(
        _ request: Request,
        stage: String,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String? {
        guard !stage.isEmpty else { return nil }
        let target = stage.hasPrefix("@") ? stage : "@\(stage)"
        let qualified = qualifiedName(request, quote: quote)
        let fileFormat: String
        switch request.format {
        case .csv: fileFormat = "(TYPE = CSV, COMPRESSION = GZIP, HEADER = TRUE)"
        case .parquet: fileFormat = "(TYPE = PARQUET)"
        case .json: fileFormat = "(TYPE = JSON)"
        }
        return """
            COPY INTO '\(escape(target))/\(sanitizedFileStem(request.table))'
            FROM \(qualified)
            FILE_FORMAT = \(fileFormat)
            OVERWRITE = FALSE
            """
    }

    // MARK: - BigQuery

    /// `EXPORT DATA` shards its output, so the URI has to carry a wildcard. A URI without one is
    /// given the shard suffix rather than refused: BigQuery rejects the statement outright, and the
    /// server's error would not say why.
    private static func bigQueryStatement(
        _ request: Request,
        uri: String,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String? {
        guard uri.hasPrefix("gs://") else { return nil }
        let shardedURI = uri.contains("*") ? uri : "\(uri.hasSuffix("/") ? uri : uri + "/")\(sanitizedFileStem(request.table))-*.\(request.format.rawValue)"
        let qualified = qualifiedName(request, quote: quote)
        let format = request.format == .json ? "NEWLINE_DELIMITED_JSON" : request.format.rawValue.uppercased()
        return """
            EXPORT DATA OPTIONS (
              uri = '\(escape(shardedURI))',
              format = '\(format)',
              overwrite = false
            ) AS SELECT * FROM \(qualified)
            """
    }

    // MARK: - Helpers

    private static func qualifiedName(_ request: Request, quote: (String) -> String) -> String {
        guard let schema = request.schema, !schema.isEmpty else { return quote(request.table) }
        return "\(quote(schema)).\(quote(request.table))"
    }

    /// A file stem the server will accept. A table name can hold characters that are legal in an
    /// identifier and not in a file name on the machine the server runs on.
    static func sanitizedFileStem(_ table: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let stem = String(table.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return stem.isEmpty ? "export" : stem
    }
}
