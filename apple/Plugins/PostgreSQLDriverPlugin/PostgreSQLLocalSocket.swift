//
//  PostgreSQLLocalSocket.swift
//  PostgreSQLDriverPlugin
//

import Foundation

// libpq takes the directory as `host` and dials `<directory>/.s.PGSQL.<port>`: apple/scripts/probes/check-postgresql-local-socket.sh.
nonisolated internal enum PostgreSQLLocalSocket {
    // The app's socket key, MySQLLocalSocket.fieldKey, which this plugin does not compile.
    static let fieldKey = "localSocketPath"
    // libpq's DEFAULT_PGSOCKET_DIR, where Homebrew and Postgres.app put the socket.
    static let defaultDirectory = "/tmp"
    static let commonDirectories = [defaultDirectory, "/var/run/postgresql"]
    // Darwin's `sun_path` is 104 bytes and the last one is the terminating NUL.
    static let maximumPathBytes = 103

    private static let fileNamePrefix = ".s.PGSQL."

    struct Endpoint: Equatable, Sendable {
        let directory: String
        let port: Int

        var socketFile: String {
            (directory == "/" ? "" : directory) + "/" + PostgreSQLLocalSocket.fileName(port: port)
        }
    }

    enum PathIssue: Equatable, Sendable {
        case notAbsolute
        case hiddenCharacter
        case comma
        case tooLong(bytes: Int)

        var message: String {
            switch self {
            case .notAbsolute:
                return String(localized: "The socket path must start with /.")
            case .hiddenCharacter:
                return String(localized: "The socket path contains a control or invisible character.")
            case .comma:
                return String(localized: "The socket path cannot contain a comma.")
            case .tooLong(let bytes):
                return String(
                    format: String(localized: "The socket path is %d bytes. macOS allows %d at most."),
                    bytes,
                    PostgreSQLLocalSocket.maximumPathBytes
                )
            }
        }
    }

    static func fileName(port: Int) -> String {
        fileNamePrefix + String(port)
    }

    // libpq looks up no host and its default socket directory in ~/.pgpass as `localhost`.
    static func pgpassHost(forHost host: String) -> String {
        host.isEmpty || host == defaultDirectory ? "localhost" : host
    }

    static func path(in fields: [String: String]) -> String? {
        guard let path = fields[fieldKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    // A path to the socket file itself gives its directory, and the port in its name wins.
    static func endpoint(path: String, port: Int) -> Endpoint {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let name = (trimmed as NSString).lastPathComponent
        if trimmed.hasPrefix("/"), name.hasPrefix(fileNamePrefix), let filePort = portInFileName(name) {
            let parent = (trimmed as NSString).deletingLastPathComponent
            return Endpoint(directory: parent.isEmpty ? "/" : parent, port: filePort)
        }
        return Endpoint(directory: trimmed, port: port)
    }

    static func issue(for endpoint: Endpoint) -> PathIssue? {
        let directory = endpoint.directory
        guard directory.hasPrefix("/") else { return .notAbsolute }
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format]
        guard !directory.unicodeScalars.contains(where: { hidden.contains($0.properties.generalCategory) }) else {
            return .hiddenCharacter
        }
        guard !directory.contains(",") else { return .comma }
        let bytes = endpoint.socketFile.utf8.count
        guard bytes <= maximumPathBytes else { return .tooLong(bytes: bytes) }
        return nil
    }

    private static func portInFileName(_ name: String) -> Int? {
        let digits = name.dropFirst(fileNamePrefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let port = Int(digits), (1...65_535).contains(port)
        else { return nil }
        return port
    }
}
