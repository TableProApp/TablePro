import Foundation

public struct FileStamp: Codable, Hashable, Sendable {
    public let modificationSeconds: Int
    public let modificationNanoseconds: Int
    public let size: Int64
    public let fileNumber: UInt64

    public var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modificationSeconds) + TimeInterval(modificationNanoseconds) / 1_000_000_000)
    }

    public static func read(_ url: URL) -> FileStamp? {
        var status = stat()
        let succeeded = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &status) == 0
        }
        guard succeeded else { return nil }
        return FileStamp(
            modificationSeconds: status.st_mtimespec.tv_sec,
            modificationNanoseconds: status.st_mtimespec.tv_nsec,
            size: status.st_size,
            fileNumber: status.st_ino
        )
    }
}
