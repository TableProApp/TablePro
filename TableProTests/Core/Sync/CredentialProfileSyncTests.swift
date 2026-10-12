//
//  CredentialProfileSyncTests.swift
//  TableProTests
//

import CloudKit
import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

struct CredentialProfileSyncTests {
    private static let zoneID = CKRecordZone.ID(
        zoneName: "TableProSync",
        ownerName: CKCurrentUserDefaultName
    )

    /// `CredentialProfile` is deployed to the CloudKit Production schema, so every field passes the
    /// gated subscript. A field added later is unverified until the snapshot and both sets move.
    @Test("The record type is deployed and every declared field is writable")
    func recordTypeIsWritable() {
        #expect(SyncRecordType.allCases.contains(.credentialProfile))
        #expect(SyncRecordType.credentialProfile.isWritable)
        #expect(CredentialProfileSyncField.writableKeys == CredentialProfileSyncField.declaredKeys)
        #expect(!CredentialProfileSyncField.declaredKeys.isEmpty)
    }

    @Test("A record of the deployed type is published")
    func recordsArePublished() {
        let record = CKRecord(
            recordType: SyncRecordType.credentialProfile.rawValue,
            recordID: CKRecord.ID(
                recordName: SyncRecordType.credentialProfile.recordName(for: "abc"),
                zoneID: Self.zoneID
            )
        )

        #expect(SyncSchemaGate.publishable(records: [record]) == [record])
        #expect(SyncSchemaGate.withheldRecordTypes(in: [record]).isEmpty)
        #expect(SyncSchemaGate.publishable(deletions: [record.recordID]) == [record.recordID])
    }

    @Test("A record name round trips to the right type")
    func recordNameRoundTrips() throws {
        let name = SyncRecordType.credentialProfile.recordName(for: "abc123")
        let parsed = try #require(SyncRecordType.parse(recordName: name))

        #expect(parsed.type == .credentialProfile)
        #expect(parsed.id == "abc123")
    }

    @Test("The type is in scope for sync rather than device-local")
    func syncScope() {
        #expect(SyncRecordType.credentialProfile.syncScope == .synced)
    }

    /// A `PasswordSource` can name a shell command. One arriving over iCloud would be a command
    /// this Mac never agreed to run, so the payload never goes into a record and the mode travels
    /// as a prompt instead.
    @MainActor
    @Test("A password source never reaches a record, and arrives back as a prompt")
    func passwordSourceIsNotSynced() throws {
        let profile = CredentialProfile(
            name: "Prod",
            username: "app",
            passwordMode: .source(.command(shell: "echo hunter2"))
        )

        let record = SyncRecordMapper.toCKRecord(profile, in: Self.zoneID)
        let encoded = String(describing: record)
        #expect(!encoded.contains("hunter2"))
        #expect(!encoded.contains("echo"))

        /// The gate drops every write while the type is unverified, so the decode side is checked
        /// against a record built by hand with the same keys the mapper would use.
        let staged = CKRecord(
            recordType: SyncRecordType.credentialProfile.rawValue,
            recordID: CKRecord.ID(
                recordName: SyncRecordType.credentialProfile.recordName(for: profile.id.uuidString),
                zoneID: Self.zoneID
            )
        )
        staged.setValue(profile.id.uuidString, forKey: "profileId")
        staged.setValue("Prod", forKey: "name")
        staged.setValue("app", forKey: "username")
        /// What `portablePasswordMode` turns a `.source` into. Staged by hand because the gate
        /// drops every field the mapper writes while the type is unverified.
        staged.setValue("prompt", forKey: "passwordMode")

        let decoded = try SyncRecordMapper.toCredentialProfile(staged)
        #expect(decoded.passwordMode == .prompt)
        #expect(decoded.username == "app")
    }

    @MainActor
    @Test("Only the three portable password modes cross the wire")
    func portableModesRoundTrip() throws {
        for (mode, expected) in [
            (CredentialPasswordMode.stored, CredentialPasswordMode.stored),
            (.prompt, .prompt),
            (.pgpass, .pgpass),
            (.source(.file(path: "/tmp/secret")), .prompt),
        ] {
            let profile = CredentialProfile(name: "P", passwordMode: mode)
            let staged = CKRecord(
                recordType: SyncRecordType.credentialProfile.rawValue,
                recordID: CKRecord.ID(
                    recordName: SyncRecordType.credentialProfile.recordName(for: profile.id.uuidString),
                    zoneID: Self.zoneID
                )
            )
            staged.setValue(profile.id.uuidString, forKey: "profileId")
            staged.setValue("P", forKey: "name")
            staged.setValue(SyncRecordMapper.portablePasswordModeForTesting(mode), forKey: "passwordMode")

            #expect(try SyncRecordMapper.toCredentialProfile(staged).passwordMode == expected)
        }
    }
}
