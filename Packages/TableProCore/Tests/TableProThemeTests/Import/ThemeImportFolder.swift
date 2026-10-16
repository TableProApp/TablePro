import Foundation
import TableProTheme

// A temporary folder holding one theme and the files it names, removed by the test that made it.
struct ThemeImportFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ text: String, as path: String) throws -> URL {
        try write(Data(text.utf8), as: path)
    }

    @discardableResult
    func write(_ data: Data, as path: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func link(_ path: String, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(path), withDestinationURL: destination)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func importTheme(_ path: String) throws -> ThemeDefinition {
        try ThemeFileImporter.importTheme(at: url.appendingPathComponent(path))
    }

    func refusal(importing path: String) -> ThemeLoadError? {
        do {
            _ = try importTheme(path)
            return nil
        } catch {
            return error as? ThemeLoadError
        }
    }
}

extension ThemeDefinition {
    func hex(_ slot: ThemeSlot) -> String? {
        overrides[slot]?.hex
    }
}
