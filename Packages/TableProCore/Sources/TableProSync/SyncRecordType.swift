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
}
