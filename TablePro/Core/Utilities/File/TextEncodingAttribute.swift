//
//  TextEncodingAttribute.swift
//  TablePro
//

import Foundation

internal struct TextEncodingAttribute: Codable, Hashable, Sendable {
    private static let name = "com.apple.TextEncoding"
    private static let separator: Character = ";"

    let value: Data

    var encoding: String.Encoding? {
        guard let text = String(data: value, encoding: .utf8) else { return nil }
        let fields = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            .split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
        if fields.count == 2, let number = UInt32(fields[1]) {
            return String.Encoding(coreFoundationEncoding: number)
        }
        guard let ianaName = fields.first, !ianaName.isEmpty else { return nil }
        return String.Encoding(ianaCharacterSetName: String(ianaName))
    }

    static func read(from url: URL) -> TextEncodingAttribute? {
        url.withUnsafeFileSystemRepresentation { path -> TextEncodingAttribute? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, name, &bytes, size, 0, 0)
            guard read > 0 else { return nil }
            return TextEncodingAttribute(value: Data(bytes.prefix(read)))
        }
    }

    func write(to url: URL) throws {
        let failure = url.withUnsafeFileSystemRepresentation { path -> POSIXErrorCode? in
            guard let path else { return .ENOENT }
            let status = value.withUnsafeBytes { buffer in
                setxattr(path, Self.name, buffer.baseAddress, buffer.count, 0, 0)
            }
            guard status != 0 else { return nil }
            return POSIXErrorCode(rawValue: errno) ?? .EIO
        }
        if let failure {
            throw POSIXError(failure)
        }
    }
}
