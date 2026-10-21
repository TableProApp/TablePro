//
//  NetworkPaneViewModel+LocalSocket.swift
//  TablePro
//

import Foundation

enum LocalSocketFileStatus: Equatable {
    case missing
    case notSocket
    case socket
}

extension NetworkPaneViewModel {
    var supportsLocalSocket: Bool {
        PluginManager.shared.defaultLocalSocketPath(for: type) != nil
    }

    var usesLocalSocket: Bool {
        supportsLocalSocket && endpoint == .localSocket
    }

    var localSocketIsDirectory: Bool {
        type.localSocketIsDirectory
    }

    var localSocketSkipsTLS: Bool {
        usesLocalSocket && localSocketIsDirectory
    }

    var localSocketPrompt: String {
        PluginManager.shared.defaultLocalSocketPath(for: type) ?? MySQLLocalSocket.defaultPath
    }

    var localSocketSuggestions: [String] {
        localSocketIsDirectory ? PostgreSQLLocalSocket.commonDirectories : []
    }

    // The driver hands the path to connect(2) unchanged, so `~` is expanded here.
    var resolvedLocalSocketPath: String? {
        let trimmed = localSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    var resolvedLocalSocketEndpoint: LocalSocketEndpoint? {
        guard usesLocalSocket, let path = resolvedLocalSocketPath else { return nil }
        return LocalSocketEndpoint(path: path, port: resolvedPort, type: type)
    }

    var pgpassEndpoint: (host: String, port: Int) {
        if localSocketIsDirectory, let socket = resolvedLocalSocketEndpoint {
            return (PostgreSQLLocalSocket.pgpassHost(forHost: socket.path), socket.port)
        }
        return (PostgreSQLLocalSocket.pgpassHost(forHost: resolvedHost), resolvedPort)
    }

    var localSocketIssues: [String] {
        guard usesLocalSocket else { return [] }
        guard let endpoint = resolvedLocalSocketEndpoint else {
            return [String(format: String(localized: "%@ is required"), String(localized: "Socket"))]
        }
        return endpoint.issue.map { [$0] } ?? []
    }

    // Advisory only: the server may start after the connection is saved.
    var localSocketFileStatus: LocalSocketFileStatus? {
        guard let endpoint = resolvedLocalSocketEndpoint, endpoint.issue == nil else { return nil }
        return Self.localSocketFileStatus(atPath: endpoint.socketFile)
    }

    // stat, not attributesOfItem, which reports a symlink to the socket as a symlink.
    nonisolated static func localSocketFileStatus(atPath path: String) -> LocalSocketFileStatus? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : nil
        }
        return info.st_mode & S_IFMT == S_IFSOCK ? .socket : .notSocket
    }
}
