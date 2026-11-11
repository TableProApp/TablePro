import ArgumentParser
import Foundation

struct OpenCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open connection URLs and database or SQL files in TablePro.",
        discussion: """
        With no target, opens TablePro. A target is a URL with a scheme, such as \
        postgresql://user@127.0.0.1:5432/app, or a file that exists. Put open or ./ before a file \
        named like a command:
          tablepro open ./status
        """
    )

    @Argument(
        help: ArgumentHelp("Connection URLs and files to open.", valueName: "url-or-file"),
        completion: .file()
    )
    var targets: [String] = []

    func run(in session: CLISession) async throws {
        let environment = session.environment
        let urls = try targets.map { target in
            try Self.resolve(target, in: environment.currentDirectory, fileExists: environment.fileExists)
        }
        try await environment.openTargets(urls)
    }

    // A word that is neither a file nor a URL is a mistyped command far more often than a file to
    // create, so it stops here instead of reaching TablePro.
    static func resolve(_ target: String, in directory: URL, fileExists: (String) -> Bool) throws -> URL {
        let file = URL(fileURLWithPath: target, relativeTo: directory).absoluteURL.standardizedFileURL
        if !target.isEmpty, fileExists(file.path) {
            return file
        }
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, target.hasPrefix(scheme + ":") {
            return url
        }
        throw CLIFailure.usage("no command or file named \"\(target)\". Run tablepro --help.")
    }
}
