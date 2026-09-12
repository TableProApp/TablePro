//
//  NativeDumpToolSelection.swift
//  TablePro
//

import Foundation

/// Which binary a tool-driven dump or restore should run, once the server it talks to is known.
///
/// `incompatible` is not `missing`: the tool is installed and cannot reach this server, so the
/// message names the version to install rather than the package that provides the command.
enum NativeDumpToolSelection: Equatable, Sendable {
    case found(path: String)
    case incompatible(String)
    case missing
}
