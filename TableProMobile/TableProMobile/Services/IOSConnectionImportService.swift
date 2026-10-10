import Foundation
import TableProConnectionLibrary
import TableProDatabase
import TableProImport
import TableProModels

@MainActor
enum IOSConnectionImportService {
    static let recognizedTypeIds: Set<String> = Set(
        (DatabaseType.allKnownTypes + [.cockroachdb, .scylladb, .turso]).map(\.rawValue)
    )

    static func environment() -> ImportEnvironment {
        ImportEnvironment(
            rules: ImportRules(
                maximumGroupDepth: LibraryGroupGraph.maxNestingDepth,
                supportsSavedQueries: false,
                supportsCredentialProfiles: false
            ),
            registeredTypeIds: recognizedTypeIds
        )
    }

    static func preview(of bundle: ConnectionBundle, fileName: String, appState: AppState) async throws -> ImportPreview {
        let library = try await IOSImportLibraryStore(appState: appState, secureStore: appState.secureStore).snapshot()
        return ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: fileName)),
            library: library,
            environment: environment()
        )
    }

    static func apply(_ plan: ImportPlan, appState: AppState, secureStore: any SecureStore) async -> ImportOutcome {
        await ImportApplier.apply(
            plan,
            library: IOSImportLibraryStore(appState: appState, secureStore: secureStore),
            savedQueries: nil
        )
    }
}
