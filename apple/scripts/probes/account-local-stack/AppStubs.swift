import Combine
import CryptoKit
import Foundation

// The app types the account sources reach for, cut down to what the probe needs.

enum KeychainStringResult: Sendable, Equatable {
    case found(String)
    case notFound
    case locked
    case userCancelled
    case authFailed
    case error(OSStatus)
}

protocol KeychainStoring: Sendable {
    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool
    func readStringResult(forKey key: String) -> KeychainStringResult
    func delete(forKey key: String)
}

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        lock.withLock { values[key] = value }
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.withLock { values[key].map { .found($0) } ?? .notFound }
    }

    func delete(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}

@MainActor
final class AppEvents {
    static let shared = AppEvents()
    let licenseStatusDidChange = PassthroughSubject<Void, Never>()
    let teamLibraryDidUpdate = PassthroughSubject<Void, Never>()
}

final class AppStorageEnvironment: Sendable {
    static let shared = AppStorageEnvironment()
    var defaults: UserDefaults { .standard }
    var supportDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("TablePro", isDirectory: true) }
}

struct SQLFavorite {
    let id: UUID
    var name: String
    var query: String
    var keyword: String?
    var folderId: UUID?
    var connectionId: UUID?
    var sortOrder = 0
}

struct SQLFavoriteFolder {
    let id: UUID
    var name: String
    var parentId: UUID?
    var sortOrder = 0
}

extension String {
    var sha256: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// The app's KeyValueStore conformance makes UserDefaults Sendable there.
extension UserDefaults: @retroactive @unchecked Sendable {}

extension AccountServices {
    static func live() -> AccountServices {
        fatalError("The probe builds each AccountServices itself")
    }
}
