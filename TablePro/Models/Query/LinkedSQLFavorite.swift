//
//  LinkedSQLFavorite.swift
//  TablePro
//

import CryptoKit
import Foundation

internal struct LinkedSQLFavorite: Identifiable, Hashable {
    let id: UUID
    let folderId: UUID
    let fileURL: URL
    let relativePath: String
    var name: String
    var keyword: String?
    var fileDescription: String?
    var mtime: Date
    var fileSize: Int64
    var encodingName: String

    var isUTF8: Bool {
        encodingName.lowercased() == "utf-8"
    }

    init(
        folderId: UUID,
        fileURL: URL,
        relativePath: String,
        name: String,
        keyword: String? = nil,
        fileDescription: String? = nil,
        mtime: Date,
        fileSize: Int64,
        encodingName: String = "utf-8"
    ) {
        self.id = Self.stableId(folderId: folderId, relativePath: relativePath)
        self.folderId = folderId
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.name = name
        self.keyword = keyword
        self.fileDescription = fileDescription
        self.mtime = mtime
        self.fileSize = fileSize
        self.encodingName = encodingName
    }

    static func stableId(folderId: UUID, relativePath: String) -> UUID {
        let key = "\(folderId.uuidString)|\(relativePath)"
        let hash = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuidBytes: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidBytes)
    }
}
