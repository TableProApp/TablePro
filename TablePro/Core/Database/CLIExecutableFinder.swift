//
//  CLIExecutableFinder.swift
//  TablePro
//

import Foundation

enum CLIExecutableFinder {
    static func findExecutable(_ name: String) -> String? {
        if let path = shell("/usr/bin/which", arguments: [name]), !path.isEmpty {
            return path
        }

        let commonPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/local/mysql/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/latest/bin/\(name)"
        ]

        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    private static func shell(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
