import Foundation

// Chosen per site: `minimal` for a tool fed data the app did not write, the user's environment for a
// tool they configured or one that has to act as their own shell would.
public enum ProcessEnvironment {
    public static let minimalNames: [String] = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
    ]

    // An app started from the Dock gets launchd's PATH, which has no Homebrew or AWS installer folder.
    public static let toolSearchPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func minimal(
        keeping extraNames: [String] = [],
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for name in minimalNames + extraNames {
            if let value = parent[name] { environment[name] = value }
        }
        return environment
    }

    public static func inherited(
        removing names: Set<String> = [],
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        parent.filter { !names.contains($0.key) }
    }

    // Only absolute folders: `which` and the shells read an empty or `.` entry as the current directory.
    public static func addingToolSearchPaths(to environment: [String: String]) -> [String: String] {
        var result = environment
        var folders = searchFolders(in: environment)
        for folder in toolSearchPaths where !folders.contains(folder) {
            folders.append(folder)
        }
        result["PATH"] = folders.joined(separator: ":")
        return result
    }

    // The first executable regular file named `name` in the PATH folders, as an absolute path.
    public static func executable(named name: String, in environment: [String: String]) -> String? {
        guard !name.isEmpty, !name.unicodeScalars.contains("/") else { return nil }
        let manager = FileManager.default
        for folder in searchFolders(in: environment) {
            let candidate = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  manager.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }

    private static func searchFolders(in environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}
