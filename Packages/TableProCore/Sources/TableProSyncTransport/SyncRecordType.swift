import CryptoKit
import Foundation

public enum SyncRecordType: String, CaseIterable, Sendable {
    case connection = "Connection"
    case group = "ConnectionGroup"
    case tag = "ConnectionTag"
    case settings = "AppSettings"
    case favorite = "SQLFavorite"
    case favoriteFolder = "SQLFavoriteFolder"
    case tableFavorite = "FavoriteTable"
    case favoriteDatabase = "FavoriteDatabase"
    case sshProfile = "SSHProfile"

    public var recordNamePrefix: String {
        switch self {
        case .connection: return "Connection_"
        case .group: return "Group_"
        case .tag: return "Tag_"
        case .settings: return "Settings_"
        case .favorite: return "Favorite_"
        case .favoriteFolder: return "FavoriteFolder_"
        case .tableFavorite: return "FavoriteTable_"
        case .favoriteDatabase: return "FavoriteDatabase_"
        case .sshProfile: return "SSHProfile_"
        }
    }

    /// A name longer than `SyncRecordName.maximumLength` carries a digest of the identifier in
    /// place of the identifier. `CKRecord.ID(recordName:)` raises `CKException` past that length,
    /// and an Objective-C exception raised inside a Swift task leaves the concurrency runtime
    /// unwound, which crashes the app seconds later from an unrelated call site. A settings
    /// category embeds a database name, so on SQLite it embeds a percent-encoded file path and
    /// has no bound at all (#2575).
    ///
    /// Every name that already fits is returned unchanged, so records that reached iCloud keep
    /// their identity. A name that did not fit could never be written, so nothing is orphaned.
    public func recordName(for id: String) -> String {
        let name = recordNamePrefix + id
        guard (name as NSString).length > SyncRecordName.maximumLength else { return name }
        return recordNamePrefix + SyncRecordName.digestPrefix + SyncRecordName.digest(of: id)
    }

    /// The identifier is only recoverable when `recordName(for:)` did not shorten it, so the push
    /// path resolves a saved record through the identifiers it sent rather than through this.
    public static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        for type in longestPrefixFirst where recordName.hasPrefix(type.recordNamePrefix) {
            return (type, String(recordName.dropFirst(type.recordNamePrefix.count)))
        }
        return nil
    }

    private static let longestPrefixFirst: [SyncRecordType] = allCases
        .sorted { $0.recordNamePrefix.count > $1.recordNamePrefix.count }
}

/// CloudKit's own limit on a record name, and how a name that would exceed it is shortened.
public enum SyncRecordName {
    /// Measured against the CloudKit framework: 255 UTF-16 code units pass and 256 raise, and the
    /// count is of UTF-16 units rather than characters or bytes (250 two-byte characters pass at
    /// 500 UTF-8 bytes; 128 emoji raise at 256 UTF-16 units). `scripts/check-cloudkit-record-name-limit.sh`
    /// re-measures it.
    public static let maximumLength = 255

    /// Names the shortening in the CloudKit dashboard, and keeps a digest from colliding with an
    /// identifier that is genuinely 64 hexadecimal characters, such as a favorite's sync id.
    public static let digestPrefix = "sha256-"

    public static func digest(of id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
