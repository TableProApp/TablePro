//
//  ConnectionEditorEngine+Name.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit

extension ConnectionEditorEngine {
    // Name never blocks: an empty one saves as the saved name, or as what the form points at.
    static func effectiveName(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> String {
        draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? fallbackName(draft, traits, context) : draft.name
    }

    static func fallbackName(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> String {
        context.savedName.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName(draft, traits) : context.savedName
    }

    static func suggestedName(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> String {
        if let path = databaseFilePath(draft, traits) {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return stem.isEmpty ? traits.displayName : stem
        }
        let host = suggestedHost(draft, traits)
        let database = traits.showsBuiltInDatabaseField ? draft.database.trimmingCharacters(in: .whitespaces) : ""
        switch (host.isEmpty, database.isEmpty) {
        case (false, false): return "\(host)/\(database)"
        case (false, true): return host
        case (true, false): return "\(traits.displayName) \(database)"
        case (true, true): return traits.displayName
        }
    }

    // A file type names its file, a remote file too; nil for a server.
    private static func databaseFilePath(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> String? {
        if draft.transport == .remoteFile {
            return draft.ssh.remoteFilePath.trimmingCharacters(in: .whitespaces)
        }
        switch traits.localFilePathField {
        case .additionalField(let fieldId):
            return (draft.fieldValues[fieldId] ?? "").trimmingCharacters(in: .whitespaces)
        case .database:
            return draft.database.trimmingCharacters(in: .whitespaces)
        case nil:
            return traits.connectionMode == .fileBased ? draft.database.trimmingCharacters(in: .whitespaces) : nil
        }
    }

    private static func suggestedHost(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> String {
        if usesLocalSocket(draft, traits) {
            return "localhost"
        }
        if let hostList = visibleHostListFields(draft, traits).first {
            let raw = draft.fieldValues[hostList.id] ?? hostList.defaultValue ?? ""
            return HostListEndpoint.parseList(raw, defaultPort: traits.defaultPort).first?.host ?? ""
        }
        if traits.connectionMode != .network {
            guard let hostFieldId = traits.serverEndpointFields?.hostFieldId,
                  let field = traits.field(hostFieldId),
                  isVisible(field, draft, traits)
            else { return "" }
            return value(of: field, in: draft).trimmingCharacters(in: .whitespaces)
        }
        return draft.host.trimmingCharacters(in: .whitespaces)
    }
}
