//
//  MainContentCoordinator+UserTypes.swift
//  TablePro
//
//  Creating, editing, renaming and dropping a named type, and keeping the type tabs in step.
//

import AppKit
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

extension MainContentCoordinator {
    private static let userTypeLogger = Logger(subsystem: "com.TablePro", category: "UserTypes")

    // MARK: - Editor

    func makeUserTypeEditor(for objectRef: DatabaseObjectRef, tabId: UUID) -> UserTypeEditorModel {
        let model = UserTypeEditorModel(objectRef: objectRef, connection: connection)
        model.onRenamed = { [weak self] renamed in
            self?.retitleUserTypeTab(tabId, to: renamed)
        }
        return model
    }

    /// The commit control and Preview SQL describe the tab on screen only.
    func publishUserTypeEditorState(tabId: UUID, hasChanges: Bool) {
        guard tabManager.selectedTabId == tabId else { return }
        toolbarState.hasTypeChanges = hasChanges
    }

    /// `onDisappear` is not ordered against the incoming view's `onAppear`, so the flag is set for
    /// whatever is selected now rather than cleared.
    func releaseUserTypeEditorState(tabId: UUID) {
        guard tabManager.selectedTabId != tabId else { return }
        let selected = tabManager.selectedTabId.flatMap { userTypeEditors[$0] }
        toolbarState.hasTypeChanges = selected?.hasChanges ?? false
    }

    func previewUserTypeChanges(tabId: UUID) {
        guard let model = userTypeEditors[tabId] else { return }
        do {
            toolbarState.previewStatements = try model.previewStatements()
        } catch {
            toolbarState.previewStatements = ["-- \(error.localizedDescription)"]
        }
        activeSheet = .sqlPreview
    }

    func saveUserTypeChanges(tabId: UUID) {
        Task { _ = await applyUserTypeChanges(tabId: tabId) }
    }

    func applyUserTypeChanges(tabId: UUID) async -> StructureSaveOutcome {
        guard let model = userTypeEditors[tabId] else { return .nothingToApply }
        guard !safeModeLevel.blocksAllWrites else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Safe Mode Is Read-Only"),
                message: String(
                    localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
                ),
                window: contentWindow
            )
            return .refused
        }
        return await model.save(window: contentWindow)
    }

    private func retitleUserTypeTab(_ tabId: UUID, to renamed: DatabaseObjectRef) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.mutate(at: index) { tab in
            tab.display.objectRef = renamed
            tab.title = QueryTabManager.objectSourceTitle(for: renamed)
        }
        tabManager.markTabRenamed(tabId)
    }

    private func userTypeTabIds(database: String?, schema: String?, name: String) -> [UUID] {
        let database = database?.nilIfEmpty ?? browseDatabaseName
        return tabManager.tabs.compactMap { tab in
            guard tab.tabType == .objectSource,
                  let ref = tab.display.objectRef,
                  ref.kind == .userType,
                  ref.name == name,
                  ref.schema == schema,
                  ref.database.nilIfEmpty ?? browseDatabaseName == database
            else { return nil }
            return tab.id
        }
    }

    // MARK: - Tables using a type

    /// A column declared with a type takes its labels, fields and checks from it, so after a change
    /// to a type every table tab on that database, in every window, reads its definition again.
    static func refreshTableDefinitions(connectionId: UUID, database: String) {
        for coordinator in activeCoordinators.values where coordinator.connectionId == connectionId {
            coordinator.refreshTableDefinitions(inDatabase: database)
        }
    }

    private func refreshTableDefinitions(inDatabase database: String) {
        let browseDatabase = browseDatabaseName
        refreshTableTabs(for: TableFreshness.Change(extent: .definition, at: .now)) { tab in
            tab.tableContext.resolvedDatabaseName(browsing: browseDatabase) == database
        }
    }

    // MARK: - New Type

    /// A nil database or schema is the one the sidebar is browsing, resolved now so the sheet
    /// creates the type where the user right-clicked even if the browser moves meanwhile.
    func newUserType(database: String?, schema: String?) {
        guard !safeModeLevel.blocksAllWrites else { return }
        let scope = services.databaseManager.resolvedScope(database: database, schema: schema, for: connectionId)
        activeSheet = .createUserType(database: scope?.database ?? database, schema: scope?.schema ?? schema)
    }

    func openCreatedUserType(_ definition: PluginUserDefinedTypeDefinition, database: String?) {
        let type = UserDefinedTypeInfo(
            name: definition.name,
            kind: UserDefinedTypeInfo.Kind(definition.kind),
            schema: definition.schema
        )
        showObjectSource(DatabaseObjectRef(userType: type, database: database ?? ""))
    }

    // MARK: - Rename

    func renameUserType(_ ref: DatabaseTreeUserTypeRef, to newName: String) {
        guard !safeModeLevel.blocksAllWrites,
              let scope = services.databaseManager.resolvedScope(
                  database: ref.database,
                  schema: ref.schema,
                  for: connectionId
              )
        else { return }
        Task {
            do {
                let generated = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                    driver.alterUserDefinedTypeStatements(type: ref.type, change: .rename(to: newName))
                }
                guard let statements = generated, !statements.isEmpty else {
                    throw DatabaseObjectCommandError.unsupported
                }
                for statement in statements {
                    try await DatabaseObjectCommandRunner.run(
                        statement,
                        in: scope,
                        connection: connection,
                        kind: .schemaMutation,
                        operationDescription: String(localized: "Rename Type"),
                        gate: ExecutionGateProvider.shared
                    )
                }
            } catch ExecutionGateError.cancelledByUser {
                return
            } catch {
                Self.userTypeLogger.error("Rename Type failed: \(error.publicLogShape, privacy: .public)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Couldn't Rename Type"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
                return
            }
            CatalogChangeService.shared.record(
                .changed(CatalogChange(connectionId: connectionId, database: scope.database, kinds: .types))
            )
            Self.refreshTableDefinitions(connectionId: connectionId, database: scope.database)
            for tabId in userTypeTabIds(database: ref.database, schema: ref.schema, name: ref.type.name) {
                guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                      let old = tab.display.objectRef else { continue }
                let renamed = DatabaseObjectRef(
                    kind: old.kind,
                    name: newName,
                    database: old.database,
                    schema: old.schema,
                    identity: old.identity,
                    typeKind: old.typeKind,
                    attributes: old.attributes
                )
                retitleUserTypeTab(tabId, to: renamed)
                await userTypeEditors[tabId]?.adoptExternalRename(renamed)
            }
        }
    }

    // MARK: - Drop

    func dropUserType(_ ref: DatabaseTreeUserTypeRef) {
        guard !safeModeLevel.blocksAllWrites,
              let scope = services.databaseManager.resolvedScope(
                  database: ref.database,
                  schema: ref.schema,
                  for: connectionId
              )
        else { return }
        let support = DatabaseObjectToolEligibility.Support.of(services.databaseManager.driver(for: connectionId))
        let prompt = UserTypeDropPrompt(
            qualifiedName: ref.type.qualifiedName,
            offersCascade: support.cascadingDropTypeKinds.contains(ref.type.kind)
        )
        UserTypeDropAlert.present(prompt: prompt, window: contentWindow) { [weak self] cascade in
            guard let self, let cascade else { return }
            self.runUserTypeDrop(ref, cascade: cascade, scope: scope)
        }
    }

    private func runUserTypeDrop(_ ref: DatabaseTreeUserTypeRef, cascade: Bool, scope: DatabaseScope) {
        Task {
            do {
                try await UserTypeDropping.drop(
                    ref.type,
                    cascade: cascade,
                    in: scope,
                    connection: connection,
                    isConfirmationPreCleared: true
                )
            } catch ExecutionGateError.cancelledByUser {
                return
            } catch {
                Self.userTypeLogger.error("Drop Type failed: \(error.publicLogShape, privacy: .public)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Drop Failed"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
                return
            }
            closeTabsForRemovedObjects(ids: userTypeTabIds(database: ref.database, schema: ref.schema, name: ref.type.name))
            if cascade { Self.refreshTableDefinitions(connectionId: connectionId, database: scope.database) }
        }
    }
}
