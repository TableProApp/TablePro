//
//  ConnectionEditorStoreTests.swift
//  TableProTests
//

import Combine
import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreTests {
    private func postgres(name: String = "Orders") -> DatabaseConnection {
        DatabaseConnection(
            name: name,
            host: "db.example.com",
            port: 5_432,
            database: "orders",
            username: "app",
            type: .postgresql
        )
    }

    // MARK: - Load

    @Test("Editing an id the library does not have shows the missing state and refuses Save")
    func missingRecord() throws {
        let fixture = try ConnectionEditorStoreFixture()
        fixture.seed([postgres()])
        let store = fixture.makeStore(.edit(connectionId: UUID()))
        #expect(store.isRecordMissing)
        #expect(!store.canSave)
    }

    @Test("A stored connection loads unchanged and reads as not edited")
    func loadIsClean() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.host == "db.example.com")
        #expect(!store.hasUnsavedChanges)
        store.update { $0.host = "other.example.com" }
        #expect(store.hasUnsavedChanges)
    }

    // MARK: - Test record

    @Test("Test signs in with the record Save would write, unowned keys included")
    func testRecordMatchesSavedRecord() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.additionalFields["mongoParam_directConnection"] = "true"
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        store.update { $0.host = "replica.example.com" }
        let tested = store.testRecord(testId: UUID())
        #expect(tested.additionalFields["mongoParam_directConnection"] == "true")

        let saved = try store.save().get()
        #expect(ConnectionEditorEngine.record(tested, reassignedTo: connection.id) == saved)
    }

    @Test("Test dials the host the editor shows, not one stored elsewhere after it opened")
    func testIgnoresHostChangedElsewhere() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.additionalFields["mongoParam_directConnection"] = "true"
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.host = "db.attacker.example"
        fixture.seed([elsewhere])
        fixture.events.connectionUpdated.send(connection.id)

        let tested = store.testRecord(testId: UUID())
        #expect(tested.host == "db.example.com")
        #expect(tested.additionalFields["mongoParam_directConnection"] == "true")
    }

    @Test("A sign-in with this Mac's credentials added elsewhere after the editor opened is not used by Test")
    func testIgnoresLocalCredentialAddedElsewhere() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.additionalFields["awsAuth"] = "profile"
        elsewhere.additionalFields["mssqlAuthMethod"] = "entra"
        fixture.seed([elsewhere])
        #expect(!ConnectionFieldCatalog.localCredentialUses(in: elsewhere.additionalFields).isEmpty)

        let tested = store.testRecord(testId: UUID())
        #expect(ConnectionFieldCatalog.localCredentialUses(in: tested.additionalFields).isEmpty)
    }

    @Test("A result is cleared by an edit to what was tested, and kept by a rename")
    func resultClearsOnTestedEdit() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.lastTestedFingerprint = ConnectionEditorEngine.testFingerprint(
            store.draft, store.traits, originalTraits: store.originalTraits, store.context
        )
        let success = ConnectionTestSuccess(typeName: "PostgreSQL", serverVersion: "16.4", elapsedMilliseconds: 42, warning: nil)
        store.testState = .succeeded(success)
        store.update { $0.name = "Renamed" }
        #expect(store.testState == .succeeded(success))
        store.update { $0.host = "elsewhere.example.com" }
        #expect(store.testState == .idle)
    }

    @Test("Name never blocks: Test and Save work with Name empty, and Save names it after the form")
    func nameNeverBlocks() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.host = "db.example.com"
            $0.database = "orders"
        }
        #expect(store.draft.name.isEmpty)
        #expect(store.namePrompt == "db.example.com/orders")
        #expect(store.canTest)
        #expect(store.canSave)

        let saved = try store.save().get()
        #expect(saved.name == "db.example.com/orders")
    }

    @Test("Emptying a saved connection's Name keeps its saved name, and the prompt shows it")
    func emptiedNameKeepsTheSavedName() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        store.update { $0.name = "" }

        #expect(store.namePrompt == "Orders")
        #expect(!store.hasUnsavedChanges)
        #expect(try store.save().get().name == "Orders")
    }

    // MARK: - Save order

    @Test("A refused Keychain write saves no record and says nothing was saved")
    func keychainFailureSavesNothing() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.name = "Orders"
            $0.credentials.password = "hunter2"
        }
        fixture.keychain.refuseWrites(true)
        #expect(store.save() == .failure(.keychainWriteFailed))
        #expect(fixture.storage.loadConnection(id: store.connectionId) == nil)
        #expect(fixture.secretKeys(for: store.connectionId).isEmpty)
    }

    @Test("A failed record write leaves no secret behind, and the retry saves under the same id")
    func failedRecordWriteCleansUpAndRetriesUnderTheSameId() throws {
        let fixture = try ConnectionEditorStoreFixture()
        fixture.seed([postgres(name: "Existing")])
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        let id = store.connectionId
        store.update {
            $0.name = "Orders"
            $0.credentials.password = "hunter2"
        }
        try fixture.makeLibraryReadOnly(true)
        #expect(store.save() == .failure(.recordWriteFailed))
        #expect(fixture.secretKeys(for: id).isEmpty)

        try fixture.makeLibraryReadOnly(false)
        let saved = try store.save().get()
        #expect(saved.id == id)
        #expect(store.connectionId == id)
        #expect(fixture.storage.loadPassword(for: id) == "hunter2")
    }

    @Test("A record deleted elsewhere is refused before any secret is written")
    func deletedRecordIsRefusedBeforeSecrets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        fixture.storage.deleteConnection(connection)
        fixture.keychain.resetWriteCount()
        store.update { $0.credentials.password = "changed" }
        #expect(store.save() == .failure(.recordMissing))
        #expect(fixture.keychain.writeCount == 0)
    }

    // MARK: - Merge

    @Test("A change made elsewhere while the editor is open survives its Save")
    func concurrentEditSurvivesSave() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.name = "Renamed in Welcome"
        elsewhere.commitMode = .manual
        elsewhere.preferredSafeModeLevel = .safeMode
        fixture.seed([elsewhere])
        fixture.events.connectionUpdated.send(connection.id)

        store.update { $0.host = "replica.example.com" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.name == "Renamed in Welcome")
        #expect(saved.commitMode == .manual)
        #expect(saved.preferredSafeModeLevel == .safeMode)
        #expect(saved.host == "replica.example.com")
    }

    @Test("A destination changed elsewhere while the editor is open is not approved by an unrelated Save")
    func concurrentDestinationIsNotApproved() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.username = "$DB_USER"
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.host = "db.attacker.example"
        fixture.seed([elsewhere])

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.host == "db.attacker.example")
        #expect(!fixture.envVarApprovals.isApproved(saved))
    }

    @Test("A variable reference added elsewhere while the editor is open is not approved by an unrelated Save")
    func concurrentReferenceIsNotApproved() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.username = "$DB_USER"
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.username = "$DB_USER$SECRET"
        fixture.seed([elsewhere])

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.username == "$DB_USER$SECRET")
        #expect(!fixture.envVarApprovals.isApproved(saved))
    }

    @Test("Saving a host change made in the editor approves the destination it shows")
    func ownDestinationIsApproved() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.username = "$DB_USER"
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        store.update { $0.host = "db2.example.com" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.host == "db2.example.com")
        #expect(fixture.envVarApprovals.isApproved(saved))
    }

    @Test("A SOCKS proxy turned on elsewhere keeps its password through an unrelated Save")
    func concurrentSOCKSKeepsItsPassword() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: "ops"))
        fixture.seed([elsewhere])
        fixture.storage.saveSOCKSProxyPassword("proxy-secret", for: connection.id)

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.socksProxyMode == elsewhere.socksProxyMode)
        #expect(fixture.storage.loadSOCKSProxyPassword(for: connection.id) == "proxy-secret")
    }

    @Test("Turning the SOCKS proxy off in the editor deletes its password")
    func turningSOCKSOffDeletesItsPassword() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: "ops"))
        fixture.seed([connection])
        fixture.storage.saveSOCKSProxyPassword("proxy-secret", for: connection.id)
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.transport == .socksProxy)

        store.update { $0.selectTransport(nil) }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.socksProxyMode == .disabled)
        #expect(fixture.storage.loadSOCKSProxyPassword(for: connection.id) == nil)
    }

    @Test("A password stored elsewhere after prompting was turned off survives an unrelated Save")
    func concurrentPromptOffKeepsThePassword() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.promptForPassword = true
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.credentials.promptsForPassword)

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.promptForPassword = false
        fixture.seed([elsewhere])
        fixture.storage.savePassword("stored-elsewhere", for: connection.id)

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(!saved.promptForPassword)
        #expect(fixture.storage.loadPassword(for: connection.id) == "stored-elsewhere")
    }

    @Test("After a Save whose record write failed, changing a password back to its loaded value still writes it")
    func failedSaveForgetsLoadedSecrets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        fixture.storage.savePassword("first", for: connection.id)
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        // The record changes too: the core's store writes nothing for a save that leaves the record as it was.
        store.update {
            $0.name = "Orders (renamed)"
            $0.credentials.password = "second"
        }
        try fixture.makeLibraryReadOnly(true)
        #expect(store.save() == .failure(.recordWriteFailed))
        #expect(fixture.storage.loadPassword(for: connection.id) == "second")

        try fixture.makeLibraryReadOnly(false)
        store.update { $0.credentials.password = "first" }
        _ = try store.save().get()
        #expect(fixture.storage.loadPassword(for: connection.id) == "first")
    }

    @Test("Local only set elsewhere while the editor is open keeps this Save's password on this Mac")
    func localOnlySetElsewhereKeepsSecretsOnThisMac() throws {
        let keychain = ScopeRecordingKeychain()
        let fixture = try ConnectionEditorStoreFixture(storageKeychain: keychain)
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.localOnly = true
        fixture.seed([elsewhere])

        store.update { $0.credentials.password = "typed-here" }
        _ = try store.save().get()

        let key = "com.TablePro.password.\(connection.id.uuidString)"
        #expect(try #require(fixture.storage.loadConnection(id: connection.id)).localOnly)
        #expect(keychain.localValue(forKey: key) == "typed-here")
        #expect(keychain.syncedValue(forKey: key) == nil)
    }

    @Test("A connection moved to another group is placed after that group's connections")
    func groupChangeTakesTheNextSortOrder() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let groupId = UUID()
        var first = postgres(name: "First")
        first.groupId = groupId
        first.sortOrder = 0
        var second = postgres(name: "Second")
        second.groupId = groupId
        second.sortOrder = 1
        let moving = postgres(name: "Moving")
        fixture.seed([first, second, moving])
        let expected = ConnectionStorage.nextSortOrder(in: [first, second, moving], groupId: groupId)
        let store = fixture.makeStore(.edit(connectionId: moving.id))

        store.update { $0.appearance.groupId = groupId }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: moving.id))
        #expect(saved.groupId == groupId)
        #expect(saved.sortOrder == expected)
        #expect(saved.sortOrder > second.sortOrder)
    }

    @Test("A new connection saved while a project is active lands in it, and one saved into a group stores none")
    func newConnectionLandsInTheActiveProject() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let acme = try fixture.projects.createProject(name: "Acme")
        let group = ConnectionGroup(name: "Inside", projectId: acme.id)
        try fixture.groups.addGroup(group)
        fixture.scope.setActiveProject(acme.id)

        let ungrouped = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        ungrouped.update { $0.host = "db.example.com" }
        let saved = try ungrouped.save().get()
        #expect(fixture.storage.loadConnection(id: saved.id)?.projectId == acme.id)

        let grouped = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        grouped.update {
            $0.host = "db.example.com"
            $0.appearance.groupId = group.id
        }
        let inGroup = try grouped.save().get()
        let stored = try #require(fixture.storage.loadConnection(id: inGroup.id))
        #expect(stored.groupId == group.id)
        #expect(stored.projectId == nil)
    }

    @Test("A connection the editor takes out of a project's group keeps that project")
    func leavingAGroupKeepsItsProject() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let acme = try fixture.projects.createProject(name: "Acme")
        let group = ConnectionGroup(name: "Inside", projectId: acme.id)
        try fixture.groups.addGroup(group)
        var moving = postgres(name: "Moving")
        moving.groupId = group.id
        fixture.seed([moving])
        let store = fixture.makeStore(.edit(connectionId: moving.id))

        store.update { $0.appearance.groupId = nil }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: moving.id))
        #expect(saved.groupId == nil)
        #expect(saved.projectId == acme.id)
    }

    @Test("A connection deleted elsewhere turns the editor into the missing state")
    func deletionElsewhereShowsMissing() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        fixture.storage.deleteConnection(connection)
        fixture.events.connectionUpdated.send(nil)
        #expect(store.isRecordMissing)
    }

    // MARK: - Profiles

    @Test("An SSH profile this Mac lacks stays linked through a Save, and no SSH secret is deleted")
    func unresolvedSSHProfileStaysLinked() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let profileId = UUID()
        var connection = postgres()
        connection.sshProfileId = profileId
        connection.sshTunnelMode = .profile(id: profileId, snapshot: SSHConfiguration(enabled: true, host: "bastion"))
        fixture.seed([connection])
        fixture.storage.saveSSHPassword("tunnel-secret", for: connection.id)

        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.sshProfileIsUnresolved)
        #expect(store.issues.contains { $0.row == .builtIn(.sshProfileMissing) && !$0.blocksSave })
        store.update { $0.name = "Renamed" }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.sshProfileId == profileId)
        guard case .profile(let id, let snapshot) = saved.sshTunnelMode else {
            Issue.record("The link was converted: \(saved.sshTunnelMode)")
            return
        }
        #expect(id == profileId)
        #expect(snapshot.host == "bastion")
        #expect(fixture.storage.loadSSHPassword(for: connection.id) == "tunnel-secret")
    }

    @Test("Save SSH as Profile reads the port the way validation does")
    func sshProfileFromInlineTrimsThePort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.selectTransport(.ssh)
            $0.ssh.host = "bastion.example.com"
            $0.ssh.port = " 2222 "
        }
        #expect(store.sshProfileFromInline().port == 2_222)
    }

    @Test("A profile deleted in Settings while the editor is open is adopted inline with its password")
    func deletedSSHProfileIsAdoptedInline() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let profile = SSHProfile(name: "Bastion", host: "bastion.example.com", username: "ops")
        #expect(fixture.sshProfiles.addProfile(profile))
        fixture.sshProfiles.saveSSHPassword("profile-secret", for: profile.id)
        var connection = postgres()
        connection.sshProfileId = profile.id
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: profile.toSSHConfiguration())
        fixture.seed([connection])

        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.ssh.profileId == profile.id)
        #expect(fixture.sshProfiles.deleteProfile(profile))
        #expect(store.draft.ssh.profileId == nil)
        #expect(store.draft.ssh.host == "bastion.example.com")
        #expect(store.draft.ssh.password == "profile-secret")

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()
        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.sshProfileId == nil)
        #expect(fixture.storage.loadSSHPassword(for: connection.id) == "profile-secret")
    }

    @Test("A credential profile deleted elsewhere is dropped by the store, whichever facet is shown")
    func deletedCredentialProfileIsDropped() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let profile = CredentialProfile(name: "Shared", username: "shared")
        #expect(fixture.credentialProfiles.addProfile(profile))
        var connection = postgres()
        connection.credentialMode = .profile(id: profile.id)
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        store.selectedFacet = .advanced
        #expect(store.draft.credentials.mode == .profile(id: profile.id))
        #expect(fixture.credentialProfiles.deleteProfile(profile))
        #expect(store.draft.credentials.mode == .inline)
    }

    // MARK: - Delete

    @Test("A delete that cannot be written is reported and the window stays")
    func failedDeleteIsReported() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        var dismissed = false
        store.dismissAction = { dismissed = true }
        try fixture.makeLibraryReadOnly(true)
        guard case .failure(let error) = store.delete() else {
            Issue.record("The delete reported success")
            return
        }
        #expect(error == .writeFailed)
        #expect(!dismissed)
        #expect(store.deleteError == .writeFailed)
        try fixture.makeLibraryReadOnly(false)
    }

    @Test("A delete cleans up what Welcome's delete cleans up")
    func deleteCleansUp() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres()
        fixture.seed([connection])
        fixture.recents.record(connection.id)
        fixture.listPreferences.setFavoritesOrder([connection.id])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        var dismissed = false
        store.dismissAction = { dismissed = true }
        guard case .success = store.delete() else {
            Issue.record("The delete failed")
            return
        }
        #expect(dismissed)
        #expect(fixture.storage.loadConnection(id: connection.id) == nil)
        #expect(fixture.recents.lastConnected[connection.id] == nil)
        #expect(!fixture.listPreferences.favoritesOrder.contains(connection.id))
    }

    // MARK: - Retype

    @Test("A retype cancels a running test, and closing deletes exactly what that test wrote")
    func retypeCancelsTestAndCleansItsSecrets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .snowflake, parsedURL: nil))
        let testId = UUID()
        store.writeSecret(.pluginField("snowflakePassword"), value: "s3cret", for: testId)
        store.pendingTestReceipts[testId] = TestSecretReceipt(testId: testId, items: [.pluginField("snowflakePassword")])
        store.testRun = TestRun(
            id: UUID(),
            testId: testId,
            fingerprint: ConnectionEditorEngine.testFingerprint(store.draft, store.traits, originalTraits: nil, store.context)
        )
        store.testState = .running

        store.retype(to: .sqlite)
        #expect(store.testState == .idle)
        #expect(store.testRun == nil)
        store.teardown()
        #expect(fixture.secretKeys(for: testId).isEmpty)
    }

    @Test("Production defaults Safe Mode to Alert for a new connection until the user picks a level")
    func productionDefaultInStore() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.setEnvironment(.production)
        #expect(store.effectiveSafeModeLevel == .alert)
        store.setEnvironment(.development)
        #expect(store.effectiveSafeModeLevel == .silent)
        store.setSafeModeLevel(.safeMode)
        store.setEnvironment(.production)
        #expect(store.effectiveSafeModeLevel == .safeMode)
    }

    // MARK: - Transports

    @Test("Picking Cloudflare on a new connection starts the cloudflared lookup")
    func cloudflaredDetectionStartsOnSelection() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        #expect(store.cloudflaredDetection == .notChecked)
        store.selectTransport(.cloudflare)
        #expect(store.cloudflaredDetection != .notChecked)
    }

    // MARK: - URL

    @Test("Copy as URL carries no password and no secure field")
    func copiedURLHasNoSecrets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        let secureIds = store.traits.declaredSecureFieldIds
        store.update {
            $0.name = "Orders"
            $0.host = "db.example.com"
            $0.credentials.username = "app"
            $0.credentials.password = "hunter2"
            for fieldId in secureIds {
                $0.fieldValues[fieldId] = "secret-\(fieldId)"
            }
        }
        let url = store.connectionURLForCopy()
        #expect(url.contains("db.example.com"))
        #expect(!url.contains("hunter2"))
        #expect(!url.contains("secret-"))
    }

    @Test("A paste on a saved connection keeps Safe Mode and the name, and Undo restores the whole draft")
    func pasteOnSavedConnection() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = postgres()
        connection.preferredSafeModeLevel = .safeMode
        fixture.seed([connection])
        fixture.storage.savePassword("original", for: connection.id)
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        let before = store.draft

        let outcome = store.applyPastedURL("postgresql://ops:pw@db2.example.com/orders?safemodelevel=0&name=Other", undoManager: nil)
        guard case .applied(let notice) = outcome else {
            Issue.record("Not applied: \(outcome)")
            return
        }
        #expect(notice.changes.contains(String(localized: "Host")))
        #expect(store.draft.host == "db2.example.com")
        #expect(store.draft.credentials.password == "pw")
        #expect(store.draft.name == "Orders")
        #expect(store.draft.safety.safeModeLevel == .safeMode)

        store.undoPastedURL()
        #expect(store.draft == before)
        #expect(store.pastedURLNotice == nil)
    }

    @Test("Typing into Host one character at a time never fills the form")
    func typingIntoHostDoesNotFill() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update { $0.host = "" }
        var typed = ""
        for character in "postgresql://app@db.example.com/orders" {
            typed.append(character)
            store.setHost(typed, undoManager: nil)
        }
        #expect(store.draft.host == "postgresql://app@db.example.com/orders")
        #expect(store.pastedURLNotice == nil)
        #expect(store.draft.database.isEmpty)
    }

    // The Host field still showed the URL and handed it back, and the second apply found nothing to list.
    @Test("A paste into Host lists what it filled, and the URL handed back again changes nothing")
    func pastedURLHandedBackIsIgnored() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        let url = "postgresql://app@db.example.com:5432/orders"

        store.setHost(url, undoManager: nil)
        let notice = try #require(store.pastedURLNotice)
        for filled in [String(localized: "Host"), String(localized: "Database"), String(localized: "Username")] {
            #expect(notice.changes.contains(filled))
        }
        #expect(notice.message != String(localized: "The URL matches this connection."))

        store.setHost(url, undoManager: nil)
        #expect(store.pastedURLNotice == notice)
        #expect(store.draft.host == "db.example.com")
        #expect(store.draft.database == "orders")
    }

    @Test("A URL without a name leaves Name empty, so the suggestion names it and follows the host")
    func pastedURLNameFollowsTheSuggestion() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))

        store.setHost("postgresql://app@db.example.com/orders", undoManager: nil)
        #expect(store.draft.name.isEmpty)
        #expect(store.namePrompt == ConnectionEditorEngine.suggestedName(store.draft, store.traits))
        #expect(store.namePrompt == "db.example.com/orders")

        store.update { $0.host = "127.0.0.1" }
        #expect(store.namePrompt == "127.0.0.1/orders")

        let imported = try ConnectionEditorStoreFixture()
            .makeStore(.new(type: nil, parsedURL: try ConnectionURLParser.parse("postgresql://app@db.example.com/orders").get()))
        #expect(imported.effectiveName == "db.example.com/orders")
    }

    @Test("A driver's unreachable-server text reads as Server not reachable, with what to check and no tab indents")
    func unreachableServerFailure() {
        let refused = NSError(domain: "PostgreSQL", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "connection to server at \"127.0.0.1\", port 5999 failed: Connection refused\n"
                + "\tIs the server running on that host and accepting TCP/IP connections?",
        ])
        let unknownHost = NSError(domain: "PostgreSQL", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "could not translate host name \"db.example.com\" to address: "
                + "nodename nor servname provided, or not known",
        ])
        let connection = DatabaseConnection(name: "Orders", type: .postgresql)

        for error in [refused, unknownHost] {
            let failure = ConnectionEditorStore.failure(for: error, connection: connection)
            #expect(failure.step == .network)
            #expect(failure.summary == String(localized: "Server not reachable"))
            #expect(failure.suggestion == ConnectionTestFailureStep.network.suggestion)
            #expect(!failure.message.contains("\t"))
        }
    }
}
