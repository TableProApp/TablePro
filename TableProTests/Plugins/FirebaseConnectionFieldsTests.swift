import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProFirebaseCore
import TableProPluginKit
import Testing

struct FirebaseRegistrySnapshotTests {
    private func snapshot(_ typeId: String) throws -> PluginMetadataSnapshot {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        return try #require(defaults.first { $0.typeId == typeId }).snapshot
    }

    @Test("Both Firebase types are API-only document engines with no SQL dialect")
    func connectionShape() throws {
        for typeId in ["Firestore", "Firebase Realtime Database"] {
            let snapshot = try snapshot(typeId)
            #expect(snapshot.connectionMode == .apiOnly)
            #expect(snapshot.editor.sqlDialect == nil)
            #expect(snapshot.queryLanguageName == "REST")
            #expect(snapshot.supportsDatabaseSwitching)
            #expect(!snapshot.supportsForeignKeys)
            #expect(!snapshot.capabilities.supportsSSH)
            #expect(snapshot.connection.category == .document)
            #expect(snapshot.iconName == "firebase-icon")
            #expect(snapshot.isDownloadable)
        }
        #expect(try snapshot("Firestore").schema.defaultPrimaryKeyColumn == FirestoreQueryBuilder.nameField)
        #expect(try snapshot("Firebase Realtime Database").schema.defaultPrimaryKeyColumn == RealtimeDatabaseQueryPlanner.keyColumn)
    }

    @Test("Both types edit whole documents and remove fields, and the Realtime Database filters on one field")
    func capabilities() throws {
        for typeId in ["Firestore", "Firebase Realtime Database"] {
            let capabilities = try snapshot(typeId).capabilities
            #expect(capabilities.supportsDocumentEditing)
            #expect(capabilities.supportsFieldRemoval)
            #expect(capabilities.columnsAreSampled)
        }
        let firestore = try snapshot("Firestore").capabilities
        #expect(firestore.supportsMatchAnyFilters && !firestore.exactRowCountIsFullScan)
        let database = try snapshot("Firebase Realtime Database").capabilities
        #expect(!database.supportsMatchAnyFilters && database.exactRowCountIsFullScan)
    }

    @Test("Neither type is ever handed SQL DROP or TRUNCATE")
    func noSQLDDL() {
        #expect(!SQLDDLFallbackPolicy.allowsGeneratedDDL(for: .firestore))
        #expect(!SQLDDLFallbackPolicy.allowsGeneratedDDL(for: .firebaseRealtimeDatabase))
    }

    @Test("The Realtime Database routes to the plugin that serves Firestore")
    func variantRouting() {
        #expect(PluginMetadataRegistry.shared.pluginTypeId(for: "Firebase Realtime Database") == "Firestore")
        #expect(DatabaseType.firebaseRealtimeDatabase.pluginTypeId == "Firestore")
        #expect(DatabaseType.firestore.pluginTypeId == "Firestore")
    }
}

struct FirebaseConnectionFieldsTests {
    private func fields(_ typeId: String) throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        return try #require(defaults.first { $0.typeId == typeId }).snapshot.connection.additionalConnectionFields
    }

    @Test("The app's field ids are the ones the driver reads")
    func fieldIdsMatchTheDriver() throws {
        #expect(try fields("Firestore").map(\.id) == [
            FirebaseFieldID.authMethod, FirebaseFieldID.serviceAccountJson, FirebaseFieldID.projectId,
            FirebaseFieldID.firestoreDatabase, FirebaseFieldID.emulatorHost
        ])
        #expect(try fields("Firebase Realtime Database").map(\.id) == [
            FirebaseFieldID.authMethod, FirebaseFieldID.serviceAccountJson, FirebaseFieldID.projectId,
            FirebaseFieldID.databaseURL, FirebaseFieldID.emulatorHost
        ])
    }

    @Test("The auth methods offered are the ones the driver accepts, service account first")
    func authMethods() throws {
        let method = try #require(try fields("Firestore").first { $0.id == FirebaseFieldID.authMethod })
        #expect(method.defaultValue == FirebaseAuthMethod.serviceAccount.rawValue)
        guard case .dropdown(let options) = method.fieldType else {
            Issue.record("Expected a dropdown field type")
            return
        }
        #expect(options.map(\.value) == FirebaseAuthMethod.allCases.map(\.rawValue))
    }

    @Test("The key replaces the built-in credentials, and the emulator host shows only for the emulator")
    func visibility() throws {
        let fields = try fields("Firestore")
        let key = try #require(fields.first { $0.id == FirebaseFieldID.serviceAccountJson })
        #expect(key.isSecure)
        #expect(key.hidesPassword)
        #expect(fields.hidesPassword(forValues: [:]))
        #expect(fields.hidesUsername(forValues: [:]))
        let emulator = try #require(fields.first { $0.id == FirebaseFieldID.emulatorHost })
        #expect(emulator.visibleWhen == FieldVisibilityRule(fieldId: FirebaseFieldID.authMethod, values: ["emulator"]))
    }
}
