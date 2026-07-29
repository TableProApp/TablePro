//
//  PreferenceKeys.swift
//  TablePro
//

import Foundation

enum PreferenceKeys {
    static let linkedFolders = DefaultsKey<[LinkedFolder]>("com.TablePro.linkedFolders")
    static let linkedSQLFolders = DefaultsKey<[LinkedSQLFolder]>("com.TablePro.linkedSQLFolders")
    static let selectedSettingsPane = DefaultsKey<String>("com.TablePro.settings.selectedPane")
    static let rowInspectorJsonFieldHeight = DefaultsKey<Double>("com.TablePro.rightSidebar.jsonFieldHeight")

    static let registeredKeyNames: [String] = [
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorJsonFieldHeight.name,
    ]

    static func columnDisplayFormats(_ scope: TableScope) -> DefaultsKey<[String: ValueDisplayFormat]> {
        DefaultsKey("com.TablePro.columns.displayFormat." + scope.storageComponent)
    }

    static func recentTables(connectionId: UUID) -> DefaultsKey<[RecentTableEntry]> {
        DefaultsKey("com.TablePro.recentTables." + connectionId.uuidString)
    }
}
