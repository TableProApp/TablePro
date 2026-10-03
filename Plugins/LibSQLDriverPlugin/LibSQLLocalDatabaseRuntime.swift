import CSQLite
import TableProPluginKit
import TableProSQLiteCore

struct LibSQLProductionLocalDatabaseRuntime: LibSQLLocalDatabaseRuntime {
    func prepareDatabase(_ db: OpaquePointer, loading extensions: [LoadableExtension]) throws {
        if !extensions.isEmpty {
            let loading = SQLiteExtensionLoading(db: db)
            try LoadableExtensionLoader.load(
                extensions,
                setLoadingEnabled: loading.setEnabled,
                loadExtension: loading.load(file:entryPoint:)
            )
        }
        SQLiteAuthorizer.install(on: db)
    }

    func stepFirst(_ statement: OpaquePointer?) -> LibSQLLocalFirstStep {
        let firstStep = SQLiteResultColumns.stepFirst(statement)
        return LibSQLLocalFirstStep(
            result: firstStep.result,
            names: firstStep.names,
            typeNames: firstStep.typeNames
        )
    }
}

extension LibSQLPluginDriver {
    convenience init(config: DriverConnectionConfig) {
        self.init(
            config: config,
            localDatabaseRuntime: LibSQLProductionLocalDatabaseRuntime()
        )
    }
}
