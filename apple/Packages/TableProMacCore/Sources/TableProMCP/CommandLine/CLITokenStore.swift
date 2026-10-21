import Foundation
import Security

public protocol CLITokenStoring: Sendable {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete()
}

public enum CLITokenStores {
    // A sandboxed run keeps its token inside the sandbox, as the app keeps its keychain there.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any CLITokenStoring {
        let sandbox = environment[MCPHandshakeLocation.sandboxEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sandbox.isEmpty else {
            return CLIKeychainTokenStore()
        }
        let directory = MCPHandshakeLocation.supportDirectory(environment: environment)
        return CLIFileTokenStore(url: directory.appendingPathComponent(CLIFileTokenStore.fileName, isDirectory: false))
    }
}

public struct CLIKeychainTokenStore: CLITokenStoring {
    static let service = "com.TablePro.cli"
    static let account = "default"

    public init() {}

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CLIFailure(.failure, "Could not read this command's token from the Keychain (\(Self.describe(status))).")
        }
        return token
    }

    public func save(_ token: String) throws {
        delete()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrLabel as String] = "TablePro command line token"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CLIFailure(.failure, "Could not save this command's token in the Keychain (\(Self.describe(status))).")
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}

public struct CLIFileTokenStore: CLITokenStoring {
    static let fileName = "cli-token"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> String? {
        guard let data = try? Data(contentsOf: url),
              let token = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public func save(_ token: String) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            delete()
            guard fileManager.createFile(
                atPath: url.path,
                contents: Data(token.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw CLIFailure(.failure, "Could not save this command's token: \(error.localizedDescription)")
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
