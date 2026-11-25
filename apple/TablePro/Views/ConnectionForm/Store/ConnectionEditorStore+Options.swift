import Foundation
import TableProPluginKit

extension ConnectionEditorStore {
    // Startup commands run in the driver's own query language, so SQL copy and highlighting fit only an SQL engine.
    var startupCommandsAreSQL: Bool {
        services.pluginManager.editorLanguage(for: draft.type) == .sql
    }

    // Nil until this connection is open as the type the form shows.
    var liveDriverRunsReadOnly: Bool? {
        guard let driver = services.databaseManager.driver(for: connectionId), driver.connection.type == draft.type else {
            return nil
        }
        return driver.runsReadOnlyStatements
    }

    var externalClientsReadOnlyNote: String? {
        guard draft.ai.externalAccess == .readOnly else { return nil }
        return ReadOnlyEnforcement.externalClientsNote(for: draft.type, liveDriverRunsReadOnly: liveDriverRunsReadOnly)
    }
}

enum QueryTimeoutInheritance {
    // The field is narrow, so words go in the subtitle and the prompt stays short.
    static func prompt(globalSeconds: Int) -> String {
        let seconds = inheritedSeconds(globalSeconds: globalSeconds)
        guard seconds > 0 else { return String(localized: "No limit") }
        return String(format: String(localized: "Global (%d)"), seconds)
    }

    static func subtitle(globalSeconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = inheritedSeconds(globalSeconds: globalSeconds)
        guard seconds > 0 else {
            return String(localized: "Leave blank to use Settings > Connections: no limit.")
        }
        let duration = Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale)
        )
        return String(format: String(localized: "Leave blank to use Settings > Connections: %@."), duration)
    }

    static func inheritedSeconds(globalSeconds: Int) -> Int {
        ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: nil, globalSeconds: globalSeconds)
    }
}
