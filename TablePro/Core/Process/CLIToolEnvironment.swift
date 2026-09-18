//
//  CLIToolEnvironment.swift
//  TablePro
//

import Foundation

/// The environment a helper process is launched with.
///
/// An app started from the Dock inherits `launchd`'s minimal PATH, not a login shell's, so a tool
/// installed by Homebrew or the AWS installer is absent from it. The AWS CLI in particular looks
/// its own `session-manager-plugin` up on PATH, so this is not only about finding the tool named
/// in the connection.
enum CLIToolEnvironment {
    static let toolPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func augmented(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var components = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for toolPath in toolPaths where !components.contains(toolPath) {
            components.append(toolPath)
        }
        environment["PATH"] = components.joined(separator: ":")
        return environment
    }
}
