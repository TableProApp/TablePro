//
//  NativeDumpResolvedTool.swift
//  TablePro
//

import Foundation

/// Which family a resolved binary belongs to, when its arguments depend on the answer.
///
/// `unidentified` is not a failure on its own: most engines never ask, and a tool that did not
/// answer `--version` is still run. It is only the engines whose option surface forked that have to
/// act on it.
enum NativeDumpToolFlavor: String, Equatable, Sendable {
    case unidentified
    case mysql
    case mariadb
}

/// The binary a dump or restore is about to run, and what the app knows about it.
///
/// It exists because an argument list is not a function of the connection alone. MariaDB renamed
/// every client in 11.0 and forked their options, and Homebrew's `mariadb` formula installs
/// MariaDB's dump tool under the name `mysqldump`, so neither the engine nor the binary's name says
/// which options the thing on disk accepts. Whoever builds the arguments gets the answer handed to
/// it rather than guessing.
struct NativeDumpResolvedTool: Equatable, Sendable {
    let name: String
    let path: String
    let flavor: NativeDumpToolFlavor
    /// What the tool printed for `--version`, kept so a descriptor can read a version out of it
    /// without probing again.
    let versionText: String?

    init(name: String, path: String, flavor: NativeDumpToolFlavor = .unidentified, versionText: String? = nil) {
        self.name = name
        self.path = path
        self.flavor = flavor
        self.versionText = versionText
    }

    var executableURL: URL {
        URL(fileURLWithPath: path)
    }
}
