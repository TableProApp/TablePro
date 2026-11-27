import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated extension DatabaseConnection: LibraryConnectionRepresentable {
    public var libraryTypeName: String { type.mobileDisplayName }
}

nonisolated extension ConnectionGroup: LibraryGroupRepresentable {}

nonisolated extension ConnectionProject: LibraryProjectRepresentable {}

nonisolated extension ConnectionTag: LibraryTagRepresentable {}

nonisolated extension SavedQuery: SavedQueryRepresentable {}

nonisolated extension SavedQueryFolder: SavedQueryFolderRepresentable {}
