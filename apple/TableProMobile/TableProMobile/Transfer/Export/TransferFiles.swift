import Foundation
import os
import TableProLogRedaction

// Each export and import works in a folder of its own under tmp, so a share, a cancel or a kill removes one folder.
nonisolated enum TransferFiles {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TransferFiles")

    // APFS takes 255 bytes of UTF-8 per name; the rest leaves room for ".partN" and an extension.
    static let maximumNameBytes = 200

    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    static var importsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)
    }

    static func makeExportFolder(in root: URL = exportsDirectory) throws -> URL {
        try makeFolder(in: root)
    }

    static func makeImportFolder(in root: URL = importsDirectory) throws -> URL {
        try makeFolder(in: root)
    }

    private static func makeFolder(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func remove(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.warning("Could not remove a transfer folder: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    // What a run killed with the app left behind; nothing is running at launch.
    static func sweep(roots: [URL] = [exportsDirectory, importsDirectory]) {
        for root in roots {
            remove(root)
        }
    }

    // The name the recipient sees, so it keeps the table's own letters and drops only what a file name cannot hold.
    static func sanitizedFileName(_ name: String, fallback: String = "Export") -> String {
        let cleaned = truncated(cleanedName(name), toBytes: maximumNameBytes).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }

    // An import reads its format and its gzip from the extension, so a long name loses letters from its stem instead.
    static func sanitizedFileNameKeepingExtension(_ name: String, fallback: String) -> String {
        let cleaned = cleanedName(name)
        let suffix = extensionSuffix(of: cleaned)
        let stem = String(decoding: cleaned.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
        let cut = truncated(stem, toBytes: maximumNameBytes - suffix.utf8.count).trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? fallback : cut) + suffix
    }

    private static let maximumExtensionBytes = 16

    private static func cleanedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
            .union(.newlines)
            .union(.illegalCharacters)
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // A leading dot hides the file, and "." or ".." name a folder.
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        return cleaned
    }

    // The last extension, and the one inside a ".gz".
    private static func extensionSuffix(of name: String) -> String {
        var suffix = ""
        var rest = name as NSString
        while true {
            let ext = rest.pathExtension
            guard !ext.isEmpty, ext.utf8.count <= maximumExtensionBytes else { break }
            suffix = "." + ext + suffix
            rest = rest.deletingPathExtension as NSString
            guard ext.lowercased() == "gz", suffix.utf8.count == ext.utf8.count + 1 else { break }
        }
        return suffix
    }

    static func fileURL(in folder: URL, name: String, fileExtension: String) -> URL {
        let base = sanitizedFileName(name)
        let file = fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
        return folder.appendingPathComponent(file, isDirectory: false)
    }

    // Every regular file the run wrote, the main file first: SQL export writes split parts beside it.
    static func writtenFiles(in folder: URL, primary: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        let files = contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let primaryName = primary.lastPathComponent
        let others = files.filter { $0.lastPathComponent != primaryName }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let hasPrimary = files.contains { $0.lastPathComponent == primaryName }
        return (hasPrimary ? [primary] : []) + others
    }

    private static func truncated(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
