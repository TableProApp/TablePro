//
//  SyncCoordinator+RemoteProfiles.swift
//  TablePro
//

import CloudKit
import Foundation
import os

extension SyncCoordinator {
    /// False when the profile could not be persisted, which withholds the pull token so the record
    /// arrives again rather than being acknowledged and lost.
    func applyRemoteCredentialProfile(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let remoteProfile: CredentialProfile
        do {
            remoteProfile = try SyncRecordMapper.toCredentialProfile(record)
        } catch {
            Self.logger.error(
                "Skipping remote credential profile \(record.recordID.recordName, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            return true
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return true }

        var profiles = services.credentialProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            /// The password mode's payload never crosses the wire, so a `.source` this Mac already
            /// holds is kept rather than replaced by the `prompt` the remote had to send instead.
            var merged = remoteProfile
            if case .source = profiles[index].passwordMode, remoteProfile.passwordMode == .prompt {
                merged.passwordMode = profiles[index].passwordMode
            }
            profiles[index] = merged
        } else {
            /// Two Macs can hold same-named profiles with different ids, which is what happens when
            /// someone recreated one by hand before they synced. The editor forbids duplicate names
            /// and every picker offers a profile by name alone, so the arriving one is renamed
            /// rather than landing as an indistinguishable second row.
            var arriving = remoteProfile
            if profiles.contains(where: { $0.name.compare(arriving.name, options: .caseInsensitive) == .orderedSame }) {
                arriving.name = Self.availableProfileName(basedOn: arriving.name, taken: profiles)
            }
            profiles.append(arriving)
        }
        guard services.credentialProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        /// The connections linked to it carry a copy of the username, which every raw reader uses.
        services.credentialProfileStorage.writeUsernameThrough(remoteProfile, byUser: false)
        return true
    }

    // False keeps the change token, so a profile this Mac failed to save arrives again.
    func applyRemoteSSHProfile(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let remoteProfile: SSHProfile
        do {
            remoteProfile = try SyncRecordMapper.toSSHProfile(record)
        } catch {
            Self.logger.error("Skipping remote SSH profile \(record.recordID.recordName, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return true
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return true }

        var profiles = services.sshProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            profiles[index] = remoteProfile
        } else {
            profiles.append(remoteProfile)
        }
        guard services.sshProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        /// A linked connection stores the profile's configuration, so an edit that arrives from
        /// another Mac has to reach those connections too or they keep tunnelling to the old host.
        services.sshProfileStorage.refreshLinkedConnections(with: remoteProfile, byUser: false)
        return true
    }
}
