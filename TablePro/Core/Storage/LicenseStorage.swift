//
//  LicenseStorage.swift
//  TablePro
//
//  Keychain + UserDefaults persistence for license data, machine ID via IOKit
//

import Foundation
import IOKit
import os

/// Persists license data using Keychain (secrets) and UserDefaults (metadata)
final class LicenseStorage {
    static let shared = LicenseStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LicenseStorage")

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let keychainLicenseKey = "com.TablePro.license.key"
        static let licensePayload = "com.TablePro.license.payload"
    }

    private init() {}

    // MARK: - License Key (Keychain)

    /// Save license key to Keychain
    func saveLicenseKey(_ key: String) {
        KeychainHelper.shared.saveString(key, forKey: Keys.keychainLicenseKey)
    }

    /// Load license key from Keychain
    func loadLicenseKey() -> String? {
        KeychainHelper.shared.loadString(forKey: Keys.keychainLicenseKey)
    }

    /// Delete license key from Keychain
    func deleteLicenseKey() {
        KeychainHelper.shared.delete(key: Keys.keychainLicenseKey)
    }

    // MARK: - Signed Payload (UserDefaults)

    /// Save cached license (including signed payload) to UserDefaults
    func saveLicense(_ license: License) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(license)
            defaults.set(data, forKey: Keys.licensePayload)
        } catch {
            Self.logger.error("Failed to encode license: \(error.localizedDescription)")
        }
    }

    /// Load cached license from UserDefaults
    func loadLicense() -> License? {
        guard let data = defaults.data(forKey: Keys.licensePayload) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(License.self, from: data)
        } catch {
            Self.logger.error("Failed to decode license: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear all license data (Keychain + UserDefaults)
    func clearAll() {
        deleteLicenseKey()
        defaults.removeObject(forKey: Keys.licensePayload)
    }

    // MARK: - Machine Identification

    /// Hardware UUID from IOKit, SHA256-hashed for privacy.
    /// Stable across OS reinstalls (tied to hardware).
    var machineId: String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let uuidCF = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  kIOPlatformUUIDKey as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() as? String
        else {
            // Fallback: use a persistent UUID stored in UserDefaults
            let fallbackKey = "com.TablePro.license.fallbackMachineId"
            if let existing = defaults.string(forKey: fallbackKey) {
                return existing.sha256
            }
            let newId = UUID().uuidString
            defaults.set(newId, forKey: fallbackKey)
            return newId.sha256
        }

        return uuidCF.sha256
    }

    /// Human-readable machine name (e.g., "John's MacBook Pro")
    var machineName: String {
        Host.current().localizedName ?? "Unknown Mac"
    }
}
