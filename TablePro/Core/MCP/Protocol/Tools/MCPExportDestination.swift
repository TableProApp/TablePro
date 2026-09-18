import Foundation

enum MCPExportDestination {
    static func resolveDownloadsURL(for path: String, format: MCPExportFormat) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "The Downloads folder is not available.")
            )
        }
        let root = downloads.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        let resolved = candidate.standardizedFileURL

        guard isContained(resolved, in: root) else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "output_path must name a file inside the Downloads folder.")
            )
        }
        guard resolved.pathExtension.lowercased() == format.fileExtension else {
            throw MCPToolExecutionError.invalidArgument(
                String(
                    format: String(localized: "output_path must end in .%@ for this format."),
                    format.fileExtension
                )
            )
        }
        guard !resolved.lastPathComponent.hasPrefix(".") else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "output_path must not name a hidden file.")
            )
        }
        return uniqueURL(for: resolved)
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.hasSuffix("/") ? parent : parent + "/"
        return parentPath == rootPath || parentPath.hasPrefix(rootPath)
    }

    static func uniqueURL(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for suffix in 1...999 {
            let candidate = directory.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension(ext)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return directory.appendingPathComponent("\(base)-\(stamp)").appendingPathExtension(ext)
    }

    static func write(_ contents: String, to url: URL) throws {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MCPToolExecutionError(
                code: .internalFailure,
                message: String(localized: "The export file could not be written.")
            )
        }
    }
}
