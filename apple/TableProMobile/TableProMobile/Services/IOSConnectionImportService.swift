import Foundation
import TableProConnectionLibrary
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
enum IOSConnectionImportService {
    // Mac plugin type ids with no DatabaseType constant.
    static let recognizedTypeIds: Set<String> = Set(
        (DatabaseType.allKnownTypes + [.cockroachdb, .scylladb, .turso]).map(\.rawValue)
    ).union(["SAP HANA", "Elasticsearch", "Typesense", "PGlite", "Presto", "KingbaseES"])

    static func environment(for appState: AppState) -> ImportEnvironment {
        ImportEnvironment(
            rules: ImportRules(
                maximumGroupDepth: LibraryGroupGraph.maxNestingDepth,
                supportsSavedQueries: appState.savedQueries.status == .ready,
                supportsCredentialProfiles: false,
                readsJumpHostKeyFiles: false
            ),
            registeredTypeIds: recognizedTypeIds
        )
    }

    static func preview(of bundle: ConnectionBundle, fileName: String, appState: AppState) async throws -> ImportPreview {
        let library = try await IOSImportLibraryStore(appState: appState, secureStore: appState.secureStore).snapshot()
        return ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: fileName)),
            library: library,
            environment: environment(for: appState)
        )
    }

    static func leavesOutSavedQueries(_ preview: ImportPreview) -> Bool {
        !preview.environment.rules.supportsSavedQueries && !preview.collected.bundle.savedQueries.isEmpty
    }

    static func apply(_ plan: ImportPlan, appState: AppState, secureStore: any SecureStore) async -> ImportOutcome {
        await ImportApplier.apply(
            plan,
            library: IOSImportLibraryStore(appState: appState, secureStore: secureStore),
            savedQueries: appState.savedQueries.importStore
        )
    }
}
