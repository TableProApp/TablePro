//
//  AIKeyStorage.swift
//  TablePro
//
//  Keychain storage for AI provider API keys.
//  Follows ConnectionStorage.swift Keychain pattern.
//

import Foundation
import os

final class AIKeyStorage {
    static let shared = AIKeyStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIKeyStorage")

    private let keychain: KeychainHelper

    init(keychain: KeychainHelper = .shared) {
        self.keychain = keychain
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        keychain.writeString(apiKey, forKey: key)
    }

    func loadAPIKey(for providerID: UUID) -> String? {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        return keychain.readStringResult(forKey: key)
            .value(label: "AI API key (providerID=\(providerID.uuidString))", logger: Self.logger)
    }

    func deleteAPIKey(for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        keychain.delete(forKey: key)
    }
}
