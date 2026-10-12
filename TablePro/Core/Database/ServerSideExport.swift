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
            return oracleStatement(request, directory: directory, escape: escapeLiteral)
        case .snowflakeStage(let stage):
            return snowflakeStatement(
                request, stage: stage, databaseType: databaseType, quote: quoteIdentifier, escape: escapeLiteral
            )
        case .googleCloudStorage(let uri):
            return bigQueryStatement(
                request, uri: uri, databaseType: databaseType, quote: quoteIdentifier, escape: escapeLiteral
            )
        }
    }

    // MARK: - Oracle

    /// The `ADD_FILE` file type for the log file. `DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE` is `3`; the constant is not
    /// named because reaching it through PL/SQL would resolve `DBMS_DATAPUMP` there, which a package named `SYS` in the
    /// caller's schema captures.
    private static let dataPumpLogFileType = 3

    /// Data Pump is a job rather than a statement, and `DBMS_DATAPUMP` is the only way to start one
    /// without shelling out to `expdp` on the server. The file lands in the directory object, so the
    /// caller is told where rather than handed anything.
    ///
    /// Every `DBMS_DATAPUMP` call is made through an `EXECUTE IMMEDIATE` of a `CALL`, which resolves the package at SQL
    /// level: the first component of a qualified name is a schema there, so a package named `SYS` planted in the schema
    /// the session runs under cannot capture it. Named directly in a `BEGIN ... END` block, `SYS.DBMS_DATAPUMP`
    /// resolves through PL/SQL, which reaches that package first and runs its `OPEN`, `ADD_FILE` and `START_JOB` with
    /// the reader's privileges (measured captured on 23ai; the `CALL` form ran the real package). The only PL/SQL-level
    /// names left are the block's own scalar variables and `NUMBER`/`VARCHAR2`, which are not schema objects.
    private static func oracleStatement(
        _ request: Request,
        directory: String,
        escape: (String) -> String
    ) -> String? {
        guard !directory.isEmpty else { return nil }
        let stem = escape(sanitizedFileStem(request.table))
        let directoryLiteral = escape(directory.uppercased())
        let nameExpr = "IN ('\(escape(request.table.uppercased()))')"
        return """
            DECLARE
              handle NUMBER;
              l_stem VARCHAR2(4000) := '\(stem)';
              l_dir VARCHAR2(4000) := '\(directoryLiteral)';
              l_name_expr VARCHAR2(4000) := '\(escape(nameExpr))';
              l_schema_expr VARCHAR2(4000) := \(schemaFilterExpression(request, escape: escape));
            BEGIN
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.OPEN(:1, :2, NULL, :3) INTO :4'
                USING 'EXPORT', 'TABLE', l_stem, OUT handle;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.ADD_FILE(:1, :2, :3)'
                USING handle, l_stem || '.dmp', l_dir;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.ADD_FILE(:1, :2, :3, NULL, \(dataPumpLogFileType))'
                USING handle, l_stem || '.log', l_dir;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.METADATA_FILTER(:1, :2, :3)'
                USING handle, 'NAME_EXPR', l_name_expr;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.METADATA_FILTER(:1, :2, :3)'
                USING handle, 'SCHEMA_EXPR', l_schema_expr;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.START_JOB(:1)' USING handle;
              EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.DETACH(:1)' USING handle;
            END;
            """
    }

    /// The Data Pump `SCHEMA_EXPR` value, as a PL/SQL expression assigned to a `VARCHAR2`.
    ///
    /// Data Pump filters by schema separately from table, so an unqualified request exports from whatever schema the
    /// session is in, which is what `USER` names. `USER` is a built-in the language resolves through `STANDARD`, not a
    /// schema object, so it is not shadowable, and it is concatenated rather than written inside a literal because a
    /// literal cannot hold an identifier.
    private static func schemaFilterExpression(_ request: Request, escape: (String) -> String) -> String {
        guard let schema = request.schema, !schema.isEmpty else {
            return "'IN (''' || USER || ''')'"
        }
        return "'\(escape("IN ('\(escape(schema.uppercased()))')"))'"
    }

    // MARK: - Snowflake

    private static func snowflakeStatement(
        _ request: Request,
        stage: String,
        databaseType: DatabaseType,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String? {
        guard !stage.isEmpty else { return nil }
        let target = stage.hasPrefix("@") ? stage : "@\(stage)"
        let qualified = qualifiedName(request, databaseType: databaseType, quote: quote)
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
        databaseType: DatabaseType,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String? {
        guard uri.hasPrefix("gs://") else { return nil }
        let shardedURI = uri.contains("*") ? uri : "\(uri.hasSuffix("/") ? uri : uri + "/")\(sanitizedFileStem(request.table))-*.\(request.format.rawValue)"
        let qualified = qualifiedName(request, databaseType: databaseType, quote: quote)
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

    private static func qualifiedName(
        _ request: Request,
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> String {
        SchemaQualifiedName.render(
            name: request.table, schema: request.schema, databaseType: databaseType, quote: quote
        )
    }

    /// A file stem the server will accept. A table name can hold characters that are legal in an
    /// identifier and not in a file name on the machine the server runs on.
    static func sanitizedFileStem(_ table: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let stem = String(table.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return stem.isEmpty ? "export" : stem
    }
}
