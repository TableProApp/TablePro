//
//  NativeDumpDescriptor.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything one engine's own dump and restore tools need, as data.
///
/// The three engines that had this hard-coded were all PostgreSQL. Generalizing it is not a matter
/// of parameterizing a binary name: `mysqldump` writes SQL to standard output where `pg_dump -Fc`
/// writes an archive to a path, `mongodump` takes a URI rather than host and port flags, and
/// `sqlite3` needs no network arguments at all. So a descriptor supplies its own argument list and
/// says how its output is delivered, rather than filling slots in one shared command shape.
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
    struct ArchiveFormat: Sendable, Equatable {
        let fileExtension: String
        let contentDescription: String
    }

    struct Request: Sendable {
        let connection: DatabaseConnection
        let database: String
        let fileURL: URL
        let password: String?

        init(connection: DatabaseConnection, database: String, fileURL: URL, password: String?) {
            self.connection = connection
            self.database = database
            self.fileURL = fileURL
            self.password = password
        }

        var host: String {
            connection.host.isEmpty ? "127.0.0.1" : connection.host
        }
    }

    /// The candidate names, in the order they are tried. More than one because a tool can ship
    /// under two names: MariaDB renamed `mysqldump` to `mariadb-dump` in 11.0 and keeps the old
    /// name only as a symlink that some builds omit.
    let backupBinaries: [String]
    let restoreBinaries: [String]

    /// What to tell the user to install when neither name resolves. There is no portable answer,
    /// so each engine names its own package.
    let installHint: String

    let archiveFormat: ArchiveFormat
    let backupDelivery: OutputDelivery
    let restoreDelivery: OutputDelivery

    /// True when the tool has no channel for a password but its own argument list, which every
    /// process on the machine can read through `ps`. Only `sqlpackage` is in that position; every
    /// other engine here takes one from the environment or a file. The flows that touch such a tool
    /// say so rather than leaving the user to find out.
    let exposesPasswordInArguments: Bool

    let backupArguments: @Sendable (Request) -> [String]
    let restoreArguments: @Sendable (Request) -> [String]
    let environment: @Sendable (Request) -> [String: String]

    init(
        backupBinaries: [String],
        restoreBinaries: [String],
        installHint: String,
        archiveFormat: ArchiveFormat,
        backupDelivery: OutputDelivery,
        restoreDelivery: OutputDelivery,
        exposesPasswordInArguments: Bool = false,
        backupArguments: @escaping @Sendable (Request) -> [String],
        restoreArguments: @escaping @Sendable (Request) -> [String],
        environment: @escaping @Sendable (Request) -> [String: String] = { _ in [:] }
    ) {
        self.backupBinaries = backupBinaries
        self.restoreBinaries = restoreBinaries
        self.installHint = installHint
        self.archiveFormat = archiveFormat
        self.backupDelivery = backupDelivery
        self.restoreDelivery = restoreDelivery
        self.exposesPasswordInArguments = exposesPasswordInArguments
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
