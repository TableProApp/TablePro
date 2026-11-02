import CryptoKit
import Darwin
import Foundation

// No other account can be the listener in a 0700 folder: the support folder, else one in the user's temp dir.
public enum MCPSocketLocation {
    public static let fileName = "mcp.sock"
    public static let fallbackFolderName = "TablePro-MCP"

    // sun_path holds the path and its terminating NUL.
    public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func fits(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= maxPathBytes
    }

    public static func primarySocket(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func fallbackFolder(temporaryDirectory: URL = userTemporaryDirectory()) -> URL {
        temporaryDirectory.appendingPathComponent(fallbackFolderName, isDirectory: true)
    }

    // Named after the support folder, so a sandboxed run and the user's app never share one.
    public static func fallbackSocket(
        forSupportDirectory supportDirectory: URL,
        temporaryDirectory: URL = userTemporaryDirectory()
    ) -> URL {
        let digest = SHA256.hash(data: Data(supportDirectory.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return fallbackFolder(temporaryDirectory: temporaryDirectory)
            .appendingPathComponent("\(name).sock", isDirectory: false)
    }

    // confstr ignores $TMPDIR, so the app and a bridge started by any host name the same folder.
    public static func userTemporaryDirectory() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return FileManager.default.temporaryDirectory }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else {
            return FileManager.default.temporaryDirectory
        }
        let path = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
        guard !path.isEmpty else { return FileManager.default.temporaryDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func isPrivateFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }
}
