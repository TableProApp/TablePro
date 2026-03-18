//
//  AIKeyStorage.swift
//  TablePro
//
//  Keychain storage for AI provider API keys.
//  Follows ConnectionStorage.swift Keychain pattern.
//

import Foundation

/// Singleton Keychain storage for AI provider API keys
final class AIKeyStorage {
    static let shared = AIKeyStorage()

    private init() {}

    // MARK: - API Key Operations

    /// Save an API key to Keychain for the given provider
    func saveAPIKey(_ apiKey: String, for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        KeychainHelper.shared.saveString(apiKey, forKey: key)
    }

    /// Load an API key from Keychain for the given provider
    func loadAPIKey(for providerID: UUID) -> String? {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    /// Delete an API key from Keychain for the given provider
    func deleteAPIKey(for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }
}
