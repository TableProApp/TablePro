//
//  MySQLDumpToolIdentifier.swift
//  TablePro
//

import Foundation
import os

/// Tells MySQL's dump and restore tools apart from MariaDB's.
///
/// The two client families no longer share an option surface, and the binary's name does not say
/// which one is on disk: Homebrew's `mariadb` formula installs MariaDB's dump tool as
/// `/opt/homebrew/bin/mysqldump`, which is the first name the descriptor tries. Measured, the two
/// announce themselves differently and the token survives a rename, because it comes from the
/// build rather than from `argv[0]`:
///
///     /opt/homebrew/bin/mysqldump from 12.3.3-MariaDB, client 10.20 for osx10.21 (arm64)
///     mysqldump  Ver 8.4.11 for macos26.6 on arm64 (Homebrew)
enum MySQLDumpToolIdentifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLDumpToolIdentifier")

    private static let mariaDBToken = "mariadb"

    /// The names MariaDB gave its clients in 11.0. A binary called one of these is MariaDB's
    /// whatever `--version` says, which is the answer when the probe cannot run at all.
    private static let mariaDBBinaryNames: Set<String> = ["mariadb-dump", "mariadb"]

    static func identify(
        name: String,
        path: String,
        probe: (String) -> String? = { CLIToolVersionProbe.versionOutput(of: $0) }
    ) -> NativeDumpResolvedTool {
        let versionText = probe(path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let flavor = self.flavor(name: name, versionText: versionText)
        if flavor == .unidentified {
            logger.warning(
                "\(name, privacy: .public) at \(path, privacy: .private(mask: .hash)) reports no readable version"
            )
        }
        return NativeDumpResolvedTool(name: name, path: path, flavor: flavor, versionText: versionText)
    }

    static func flavor(name: String, versionText: String?) -> NativeDumpToolFlavor {
        if let versionText, !versionText.isEmpty {
            return versionText.lowercased().contains(mariaDBToken) ? .mariadb : .mysql
        }
        return mariaDBBinaryNames.contains(name.lowercased()) ? .mariadb : .unidentified
    }

    /// The MySQL release the tool belongs to, read from its `--version` line.
    ///
    /// `Ver` is not always that number. MySQL 8 prints `mysqldump  Ver 8.4.11 for macos26.6 on
    /// arm64 (Homebrew)`, where it is, but 5.7 prints `mysqldump  Ver 10.13 Distrib 5.7.44, for
    /// ...`, where `Ver` is the tool's own version and `Distrib` is the release. Reading `Ver`
    /// alone makes a 5.7 client look newer than an 8.4 one, which is the wrong way round for every
    /// question worth asking of it.
    static func majorVersion(fromVersionText versionText: String?) -> Int? {
        guard let versionText else { return nil }
        for pattern in [#"\bDistrib\s+"#, #"\bVer\s+"#] {
            guard let marker = versionText.range(of: pattern, options: .regularExpression) else { continue }
            let digits = versionText[marker.upperBound...].prefix { $0.isNumber }
            if let major = Int(digits) { return major }
        }
        return nil
    }
}
