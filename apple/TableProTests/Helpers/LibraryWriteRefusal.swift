import Foundation

// A library folder that refuses every write: connections.json beside it and the core's store in Core/. The core resets
// Core/'s mode before each write, so a mode alone cannot refuse it; the immutable flag does, and reads still work.
enum LibraryWriteRefusal {
    static func set(_ refused: Bool, in directory: URL) throws {
        let folders = [directory, directory.appendingPathComponent("Core", isDirectory: true)]
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.setAttributes([.immutable: refused], ofItemAtPath: folder.path)
        }
    }
}
