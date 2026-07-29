import Foundation

struct FileBookmarkStore: Sendable {
    private let suiteName: String?
    private static let keyPrefix = "com.TablePro.fileBookmark."

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func save(_ bookmark: Data, for id: UUID) {
        defaults.set(bookmark, forKey: Self.keyPrefix + id.uuidString)
    }

    func bookmark(for id: UUID) -> Data? {
        defaults.data(forKey: Self.keyPrefix + id.uuidString)
    }

    func delete(for id: UUID) {
        defaults.removeObject(forKey: Self.keyPrefix + id.uuidString)
    }
}
