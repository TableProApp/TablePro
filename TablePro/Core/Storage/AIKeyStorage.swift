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

    private init() {}

    func saveAPIKey(_ apiKey: String, for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        KeychainHelper.shared.writeString(apiKey, forKey: key)
    }

    func loadAPIKey(for providerID: UUID) -> String? {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        switch KeychainHelper.shared.readStringResult(forKey: key) {
        case .found(let value):
            return value
        case .locked:
            Self.logger.warning(
                "AI API key unavailable — Keychain locked (providerID=\(providerID.uuidString, privacy: .public))"
            )
            return nil
        case .notFound:
            return nil
        }
    }

    func deleteAPIKey(for providerID: UUID) {
        let key = "com.TablePro.aikey.\(providerID.uuidString)"
        KeychainHelper.shared.delete(forKey: key)
    }
}
