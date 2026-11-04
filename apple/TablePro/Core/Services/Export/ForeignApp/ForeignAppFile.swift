//
//  ForeignAppFile.swift
//  TablePro
//

import Foundation

enum ForeignAppFile {
    enum ReadError: Error {
        case notRegularFile
        case tooLarge
    }

    static let maximumByteCount = 16 * 1_024 * 1_024

    // A path another app's settings name can be crafted, such as a project's `.idea` folder linked to
    // `/dev/zero` or a pipe. O_NONBLOCK keeps the open of a pipe from waiting for a writer.
    static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegularFile }
        guard info.st_size <= maximumByteCount else { throw ReadError.tooLarge }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else { throw ReadError.tooLarge }
        return data
    }

    static func isMissing(_ error: any Error) -> Bool {
        (error as? POSIXError)?.code == .ENOENT
    }
}
