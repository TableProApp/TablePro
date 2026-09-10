//
//  NativeDumpDescriptor.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything one engine's own dump and restore need, as data.
///
/// The three engines that had this hard-coded were all PostgreSQL. Generalizing it is not a matter
/// of parameterizing a binary name: `mysqldump` writes SQL to standard output where `pg_dump -Fc`
/// writes an archive to a path, `mongodump` takes a URI rather than host and port flags, `sqlite3`
/// needs no network arguments at all, and DuckDB runs no binary because its dump is a statement its
/// own in-process engine executes. So a descriptor names its mechanism and supplies its own
/// arguments or statements, rather than filling slots in one shared command shape.
struct NativeDumpDescriptor: Sendable {
    /// How the tool hands back what it produced. This is the difference that no shared argument
    /// list can paper over.
    enum OutputDelivery: Sendable, Equatable {
        /// The tool is told where to write, and writes there itself.
        case toolWritesFile
        /// The tool writes to standard output and the caller redirects it to the file.
        case standardOutput
    }

    /// What the caller offers as a file name, and what a restore will accept back.
    ///
    /// `id` exists because one engine can offer two: DuckDB writes either a single `.duckdb` file
    /// or a directory of Parquet, and the sheet has to name which one it is about to write.
    struct ArchiveFormat: Sendable, Equatable, Identifiable {
        let id: String
        let fileExtension: String
        let contentDescription: String
        /// A destination the user chooses with an open panel rather than a save panel, because the
        /// engine writes a folder of files rather than one file.
        let producesDirectory: Bool

        init(
            id: String = "default",
            fileExtension: String,
            contentDescription: String,
            producesDirectory: Bool = false
        ) {
            self.id = id
            self.fileExtension = fileExtension
            self.contentDescription = contentDescription
            self.producesDirectory = producesDirectory
        }
    }

    struct Request: Sendable {
        let connection: DatabaseConnection
        let database: String
        let fileURL: URL
        let password: String?
        let scope: NativeDumpScope

        /// The engine's own name for the database in front of it, read from the live connection.
        ///
        /// Only DuckDB needs one, and it needs it badly: `COPY FROM DATABASE <src> TO <dst>` names
        /// a catalog, and DuckDB derives that catalog from the file's basename. Measured, a file
        /// `my-weird.name.db` attaches as `my-weird`, and `COPY FROM DATABASE main` fails with
        /// `Catalog "main" does not exist`. So neither the file name nor a constant will do.
        let currentCatalog: String?

        /// The path a file-backed driver actually opens.
        ///
        /// SQLite keeps it in `database`, while DuckDB and libSQL keep it in a plugin-declared
        /// additional field and leave `database` empty. Resolved by the caller through
        /// `LocalFilePathField` rather than guessed here, because reading `connection.database` for
        /// libSQL handed `sqlite3` an empty path, which exits 0 and writes a 52-byte file that the
        /// result sheet then reports as a successful backup.
        let localFilePath: String?

        init(
            connection: DatabaseConnection,
            database: String,
            fileURL: URL,
            password: String?,
            scope: NativeDumpScope = .wholeDatabase,
            currentCatalog: String? = nil,
            localFilePath: String? = nil
        ) {
            self.connection = connection
            self.database = database
            self.fileURL = fileURL
            self.password = password
            self.scope = scope
            self.currentCatalog = currentCatalog
            self.localFilePath = localFilePath
        }

        var host: String {
            connection.host.isEmpty ? "127.0.0.1" : connection.host
        }
    }

    /// A tool on the user's Mac that the app spawns.
    struct CommandLineTool: Sendable {
        /// The candidate names, in the order they are tried. More than one because a tool can ship
        /// under two names: MariaDB renamed `mysqldump` to `mariadb-dump` in 11.0 and keeps the old
        /// name only as a symlink that some builds omit.
        let backupBinaries: [String]
        let restoreBinaries: [String]

        /// What to tell the user to install when neither name resolves. There is no portable
        /// answer, so each engine names its own package.
        let installHint: String

        let backupDelivery: OutputDelivery
        let restoreDelivery: OutputDelivery

        /// True when the tool has no channel for a password but its own argument list, which every
        /// process on the machine can read through `ps`. Only `sqlpackage` is in that position;
        /// every other engine here takes one from the environment or a file. The flows that touch
        /// such a tool say so rather than leaving the user to find out.
        let exposesPasswordInArguments: Bool

        /// True when the tool reads a password from neither the environment nor standard input, so
        /// the only channel left is a file written at mode `0600`. Declared rather than inferred
        /// from the binary's name, which is what `buildCommand` used to do.
        let needsCredentialsFile: Bool

        let backupArguments: @Sendable (Request) -> [String]
        let restoreArguments: @Sendable (Request) -> [String]
        let environment: @Sendable (Request) -> [String: String]

        init(
            backupBinaries: [String],
            restoreBinaries: [String],
            installHint: String,
            backupDelivery: OutputDelivery,
            restoreDelivery: OutputDelivery,
            exposesPasswordInArguments: Bool = false,
            needsCredentialsFile: Bool = false,
            backupArguments: @escaping @Sendable (Request) -> [String],
            restoreArguments: @escaping @Sendable (Request) -> [String],
            environment: @escaping @Sendable (Request) -> [String: String] = { _ in [:] }
        ) {
            self.backupBinaries = backupBinaries
            self.restoreBinaries = restoreBinaries
            self.installHint = installHint
            self.backupDelivery = backupDelivery
            self.restoreDelivery = restoreDelivery
            self.exposesPasswordInArguments = exposesPasswordInArguments
            self.needsCredentialsFile = needsCredentialsFile
            self.backupArguments = backupArguments
            self.restoreArguments = restoreArguments
            self.environment = environment
        }

        func binaries(for kind: NativeDumpKind) -> [String] {
            kind == .backup ? backupBinaries : restoreBinaries
        }

        func arguments(for kind: NativeDumpKind, request: Request) -> [String] {
            kind == .backup ? backupArguments(request) : restoreArguments(request)
        }

        func delivery(for kind: NativeDumpKind) -> OutputDelivery {
            kind == .backup ? backupDelivery : restoreDelivery
        }
    }

    /// Statements the engine already in front of the app runs for itself.
    ///
    /// There is no binary to find, no password to hand over and nothing to reap, which is why this
    /// cannot be a `CommandLineTool` with an empty argument list. An embedded engine also has no
    /// server to write on the user's behalf, so the file lands where the panel picked.
    struct EngineStatements: Sendable {
        /// The statements for one direction, in order. `alias` is a name for the attached backup,
        /// unique per run so a `DETACH` that could not run leaves nothing blocking the next one.
        let backupStatements: @Sendable (Request, String) -> [String]
        let restoreStatements: @Sendable (Request, String) -> [String]

        /// Run after a failure and ignored. A `DETACH` inside an aborted transaction fails too, and
        /// the caller has the engine's real error to report rather than this one.
        let cleanupStatements: @Sendable (String) -> [String]

        func statements(for kind: NativeDumpKind, request: Request, alias: String) -> [String] {
            kind == .backup ? backupStatements(request, alias) : restoreStatements(request, alias)
        }
    }

    enum Mechanism: Sendable {
        case commandLineTool(CommandLineTool)
        case engineStatements(EngineStatements)
    }

    let mechanism: Mechanism
    let archiveFormat: ArchiveFormat
    let objectScope: NativeDumpObjectScope

    /// True when the tool opens the database file itself and so cannot reach a connection that has
    /// no local file. libSQL claims the SQLite descriptor and reaches either a file or a Turso URL,
    /// and only the file can be handed to `sqlite3`.
    let requiresLocalFile: Bool

    init(
        mechanism: Mechanism,
        archiveFormat: ArchiveFormat,
        objectScope: NativeDumpObjectScope,
        requiresLocalFile: Bool = false
    ) {
        self.mechanism = mechanism
        self.archiveFormat = archiveFormat
        self.objectScope = objectScope
        self.requiresLocalFile = requiresLocalFile
    }

    var commandLineTool: CommandLineTool? {
        guard case .commandLineTool(let tool) = mechanism else { return nil }
        return tool
    }

    var engineStatements: EngineStatements? {
        guard case .engineStatements(let statements) = mechanism else { return nil }
        return statements
    }

    var exposesPasswordInArguments: Bool {
        commandLineTool?.exposesPasswordInArguments ?? false
    }
}
