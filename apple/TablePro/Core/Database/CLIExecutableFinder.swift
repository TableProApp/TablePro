//
//  CLIExecutableFinder.swift
//  TablePro
//

import Foundation
import TableProProcess

enum CLIExecutableFinder {
    static func findExecutable(_ name: String) -> String? {
        let environment = ProcessEnvironment.addingToolSearchPaths(to: ProcessInfo.processInfo.environment)
        if let path = ProcessEnvironment.executable(named: name, in: environment) {
            return path
        }

        let folders = [
            "/usr/local/mysql/bin",
            "/Applications/Postgres.app/Contents/Versions/latest/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent("google-cloud-sdk/bin"),
        ]
        return ProcessEnvironment.executable(named: name, in: ["PATH": folders.joined(separator: ":")])
    }
}
