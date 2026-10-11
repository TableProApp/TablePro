//
//  GitExecutableLocator.swift
//  TablePro
//

import Foundation

internal struct GitExecutableLocator: Sendable {
    static let developerDirectoryLink = "/var/db/xcode_select_link"
    static let homebrewCandidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
    static let commandLineToolsGit = "/Library/Developer/CommandLineTools/usr/bin/git"
    static let defaultXcodeGit = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
    static let installerShim = "/usr/bin/git"

    let isExecutable: @Sendable (String) -> Bool
    let developerDirectory: @Sendable () -> String?

    static let system = GitExecutableLocator(
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        developerDirectory: { try? FileManager.default.destinationOfSymbolicLink(atPath: developerDirectoryLink) }
    )

    func candidates() -> [String] {
        var paths = Self.homebrewCandidates
        if let developerDirectory = developerDirectory(), developerDirectory.hasPrefix("/") {
            paths.append((developerDirectory as NSString).appendingPathComponent("usr/bin/git"))
        }
        paths.append(Self.commandLineToolsGit)
        paths.append(Self.defaultXcodeGit)

        var seen: Set<String> = []
        return paths.filter { path in
            let standardized = (path as NSString).standardizingPath
            guard standardized != Self.installerShim else { return false }
            return seen.insert(standardized).inserted
        }
    }

    func locate() -> URL? {
        candidates().first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}
