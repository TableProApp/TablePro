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

    var localSocketPrompt: String {
        PluginManager.shared.defaultLocalSocketPath(for: type) ?? MySQLLocalSocket.defaultPath
    }

    // The driver hands the path to connect(2) unchanged, so `~` is expanded here.
    var resolvedLocalSocketPath: String? {
        let trimmed = localSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    var localSocketIssues: [String] {
        guard usesLocalSocket else { return [] }
        guard let path = resolvedLocalSocketPath else {
            return [String(format: String(localized: "%@ is required"), String(localized: "Socket"))]
        }
        guard let issue = MySQLLocalSocket.issue(for: path) else { return [] }
        return [issue.message]
    }

    // Advisory only: the server may start after the connection is saved.
    var localSocketFileStatus: LocalSocketFileStatus? {
        guard usesLocalSocket,
              let path = resolvedLocalSocketPath,
              MySQLLocalSocket.issue(for: path) == nil
        else { return nil }
        return Self.localSocketFileStatus(atPath: path)
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
