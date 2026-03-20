//
//  SSHProfileStorage.swift
//  TablePro
//

import Foundation
import os

final class SSHProfileStorage {
    static let shared = SSHProfileStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHProfileStorage")

    private let profilesKey = "com.TablePro.sshProfiles"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastLoadFailed = false

    private init() {}

    // MARK: - Profile CRUD

    func loadProfiles() -> [SSHProfile] {
        guard let data = defaults.data(forKey: profilesKey) else {
            lastLoadFailed = false
            return []
        }

        do {
            let profiles = try decoder.decode([SSHProfile].self, from: data)
            lastLoadFailed = false
            return profiles
        } catch {
            Self.logger.error("Failed to load SSH profiles: \(error)")
            lastLoadFailed = true
            return []
        }
    }

    func saveProfiles(_ profiles: [SSHProfile]) {
        guard !lastLoadFailed else {
            Self.logger.warning("Refusing to save SSH profiles: previous load failed (would overwrite existing data)")
            return
        }
        do {
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: profilesKey)
            SyncChangeTracker.shared.markDirty(.sshProfile, ids: profiles.map { $0.id.uuidString })
        } catch {
            Self.logger.error("Failed to save SSH profiles: \(error)")
        }
    }

    func saveProfilesWithoutSync(_ profiles: [SSHProfile]) {
        guard !lastLoadFailed else { return }
        do {
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: profilesKey)
        } catch {
            Self.logger.error("Failed to save SSH profiles: \(error)")
        }
    }

    func addProfile(_ profile: SSHProfile) {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return }
        profiles.append(profile)
        saveProfiles(profiles)
    }

    func updateProfile(_ profile: SSHProfile) {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveProfiles(profiles)
        }
    }

    func deleteProfile(_ profile: SSHProfile) {
        SyncChangeTracker.shared.markDeleted(.sshProfile, id: profile.id.uuidString)
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles(profiles)

        deleteSSHPassword(for: profile.id)
        deleteKeyPassphrase(for: profile.id)
        deleteTOTPSecret(for: profile.id)
    }

    func profile(for id: UUID) -> SSHProfile? {
        loadProfiles().first { $0.id == id }
    }

    // MARK: - SSH Password Storage

    func saveSSHPassword(_ password: String, for profileId: UUID) {
        let key = "com.TablePro.sshprofile.password.\(profileId.uuidString)"
        KeychainHelper.shared.saveString(password, forKey: key)
    }

    func loadSSHPassword(for profileId: UUID) -> String? {
        let key = "com.TablePro.sshprofile.password.\(profileId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteSSHPassword(for profileId: UUID) {
        let key = "com.TablePro.sshprofile.password.\(profileId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - Key Passphrase Storage

    func saveKeyPassphrase(_ passphrase: String, for profileId: UUID) {
        let key = "com.TablePro.sshprofile.keypassphrase.\(profileId.uuidString)"
        KeychainHelper.shared.saveString(passphrase, forKey: key)
    }

    func loadKeyPassphrase(for profileId: UUID) -> String? {
        let key = "com.TablePro.sshprofile.keypassphrase.\(profileId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteKeyPassphrase(for profileId: UUID) {
        let key = "com.TablePro.sshprofile.keypassphrase.\(profileId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }

    // MARK: - TOTP Secret Storage

    func saveTOTPSecret(_ secret: String, for profileId: UUID) {
        let key = "com.TablePro.sshprofile.totpsecret.\(profileId.uuidString)"
        KeychainHelper.shared.saveString(secret, forKey: key)
    }

    func loadTOTPSecret(for profileId: UUID) -> String? {
        let key = "com.TablePro.sshprofile.totpsecret.\(profileId.uuidString)"
        return KeychainHelper.shared.loadString(forKey: key)
    }

    func deleteTOTPSecret(for profileId: UUID) {
        let key = "com.TablePro.sshprofile.totpsecret.\(profileId.uuidString)"
        KeychainHelper.shared.delete(key: key)
    }
}
