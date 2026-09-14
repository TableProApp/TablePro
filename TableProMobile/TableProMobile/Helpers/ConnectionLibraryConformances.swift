import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated extension DatabaseConnection: LibraryConnectionRepresentable {
    public var libraryTypeName: String { type.mobileDisplayName }
}

nonisolated extension ConnectionGroup: LibraryGroupRepresentable {}

nonisolated extension ConnectionTag: LibraryTagRepresentable {}
