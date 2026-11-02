import Foundation
import TableProSnowflakeCore

enum SnowflakeIdTokenStore {
    private static let cache = SnowflakeTokenCache(
        storage: SnowflakeKeychainTokenStorage(service: "com.TablePro.SnowflakeDriverPlugin.idToken")
    )

    static func token(for account: SnowflakeAccount, user: String) -> String? {
        cache.token(for: account, user: user)
    }

    static func store(_ token: String, for account: SnowflakeAccount, user: String) {
        cache.store(token, for: account, user: user)
    }

    static func clear(for account: SnowflakeAccount, user: String) {
        cache.clear(for: account, user: user)
    }
}
