//
//  FileTextWriter.swift
//  TablePro
//

import Foundation

internal enum FileTextWriter {
    enum WriteError: Error, Equatable {
        case unrepresentable(FileTextEncoding)
    }

    typealias AttributeApplier = (TextEncodingAttribute, URL) throws -> Void

    private static let stagingPrefix = ".tablepro-save-"

    static func write(_ text: String, to url: URL, as encoding: FileTextEncoding) throws {
        guard let bytes = encoding.bytes(of: text) else {
            throw WriteError.unrepresentable(encoding)
        }
        try replaceContents(of: url, with: bytes, attribute: encoding.attribute)
    }

    static func replaceContents(
        of url: URL,
        with bytes: Data,
        attribute: TextEncodingAttribute?,
        applyingAttribute applyAttribute: AttributeApplier = { attribute, url in try attribute.write(to: url) }
    ) throws {
        let destination = url.resolvingSymlinksInPath()
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix + UUID().uuidString)
        do {
            try bytes.write(to: staging, options: .withoutOverwriting)
            if let attribute {
                try applyAttribute(attribute, staging)
            }
            try carryPermissions(of: destination, to: staging)
            try move(staging, over: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw describing(error, at: destination)
        }
    }

    private static func carryPermissions(of destination: URL, to staging: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let permissions = attributes[.posixPermissions] else { return }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path)
    }

    private static func move(_ staging: URL, over destination: URL) throws {
        let failure = staging.withUnsafeFileSystemRepresentation { stagingPath -> POSIXErrorCode? in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> POSIXErrorCode? in
                guard let stagingPath, let destinationPath else { return .ENOENT }
                guard rename(stagingPath, destinationPath) != 0 else { return nil }
                return POSIXErrorCode(rawValue: errno) ?? .EIO
            }
        }
        if let failure {
            throw POSIXError(failure)
        }
    }

    private static func describing(_ error: Error, at destination: URL) -> Error {
        CocoaError(writeErrorCode(for: error), userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: error])
    }

    private static func writeErrorCode(for error: Error) -> CocoaError.Code {
        if let cocoaError = error as? CocoaError {
            return cocoaError.code
        }
        guard let posixError = error as? POSIXError else { return .fileWriteUnknown }
        switch posixError.code {
        case .EACCES, .EPERM:
            return .fileWriteNoPermission
        case .ENOSPC, .EDQUOT:
            return .fileWriteOutOfSpace
        case .EROFS:
            return .fileWriteVolumeReadOnly
        default:
            return .fileWriteUnknown
        }
    }
}
