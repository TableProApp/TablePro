import Foundation

public enum SyncRecordType: String, CaseIterable, Sendable {
    case connection = "Connection"
    case group = "ConnectionGroup"
    case tag = "ConnectionTag"
    case settings = "AppSettings"
    case favorite = "SQLFavorite"
    case favoriteFolder = "SQLFavoriteFolder"
    case tableFavorite = "FavoriteTable"
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
        case .sshProfile: return "SSHProfile_"
        }
    }

    public func recordName(for id: String) -> String {
        recordNamePrefix + id
    }

    public static func parse(recordName: String) -> (type: SyncRecordType, id: String)? {
        for type in longestPrefixFirst where recordName.hasPrefix(type.recordNamePrefix) {
            return (type, String(recordName.dropFirst(type.recordNamePrefix.count)))
        }
        return nil
    }

    private static let longestPrefixFirst: [SyncRecordType] = allCases
        .sorted { $0.recordNamePrefix.count > $1.recordNamePrefix.count }
}
