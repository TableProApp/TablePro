import Foundation
import os
import TableProSnowflakeCore

enum SnowflakeMFATokenStore {
    private static let cache = SnowflakeTokenCache(
        storage: SnowflakeKeychainTokenStorage(service: "com.TablePro.SnowflakeDriverPlugin.mfaToken")
    )
    private static let rejectedPasscodes = OSAllocatedUnfairLock(initialState: [String: Date]())

    static func token(for account: SnowflakeAccount, user: String) -> String? {
        cache.token(for: account, user: user)
    }

    static func store(_ token: String, for account: SnowflakeAccount, user: String) {
        cache.store(token, for: account, user: user)
    }

    static func clear(for account: SnowflakeAccount, user: String) {
        cache.clear(for: account, user: user)
    }

    static let rejectedPasscodeLifetime: TimeInterval = 300

    static func markPasscodeRejected(_ passcode: String, for account: SnowflakeAccount, user: String) {
        guard !passcode.isEmpty else { return }
        let key = "\(account.tokenKey(user: user)):\(passcode)"
        rejectedPasscodes.withLock { rejected in
            rejected = rejected.filter {
                Date().timeIntervalSince($0.value) < rejectedPasscodeLifetime
            }
            rejected[key] = Date()
        }
    }

    static func isPasscodeRejected(_ passcode: String, for account: SnowflakeAccount, user: String) -> Bool {
        guard !passcode.isEmpty else { return false }
        let key = "\(account.tokenKey(user: user)):\(passcode)"
        return rejectedPasscodes.withLock {
            guard let rejectedAt = $0[key] else { return false }
            return Date().timeIntervalSince(rejectedAt) < rejectedPasscodeLifetime
        }
    }
}
