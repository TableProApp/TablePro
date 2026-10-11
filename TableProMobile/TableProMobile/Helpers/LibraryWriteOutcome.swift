import Foundation

nonisolated enum LibraryWriteOutcome: Equatable, Sendable {
    case applied
    case unchanged
    case missing
    case refused
    case invalidPlacement

    var isSaved: Bool {
        self == .applied || self == .unchanged
    }
}

nonisolated enum LibraryItemKind: Equatable, Sendable {
    case connection
    case group
    case tag
}

nonisolated enum LibraryWriteFailure: Equatable, Sendable {
    case removed(LibraryItemKind)
    case libraryUnavailable(LibraryItemKind)
    case invalidPlacement

    init?(_ outcome: LibraryWriteOutcome, kind: LibraryItemKind) {
        switch outcome {
        case .applied, .unchanged:
            return nil
        case .missing:
            self = .removed(kind)
        case .refused:
            self = .libraryUnavailable(kind)
        case .invalidPlacement:
            self = .invalidPlacement
        }
    }

    var closesForm: Bool {
        guard case .removed = self else { return false }
        return true
    }

    var title: String {
        switch self {
        case .removed(.connection):
            String(localized: "Connection Deleted")
        case .removed(.group):
            String(localized: "Group Deleted")
        case .removed(.tag):
            String(localized: "Tag Deleted")
        case .libraryUnavailable(.connection):
            String(localized: "Connection Not Saved")
        case .libraryUnavailable(.group), .invalidPlacement:
            String(localized: "Group Not Saved")
        case .libraryUnavailable(.tag):
            String(localized: "Tag Not Saved")
        }
    }

    var message: String {
        switch self {
        case .removed(.connection):
            String(localized: "This connection no longer exists. It may have been removed from another device.")
        case .removed(.group):
            String(localized: "This group no longer exists. It may have been removed from another device.")
        case .removed(.tag):
            String(localized: "This tag no longer exists. It may have been removed from another device.")
        case .libraryUnavailable:
            String(localized: "Your connections could not be loaded, so this change was not saved.")
        case .invalidPlacement:
            String(localized: "This group can't go inside the parent you chose. It may have changed on another device.")
        }
    }
}
