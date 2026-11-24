//
//  DatabaseURLConnectionMatch.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DatabaseURLConnectionMatch {
    // A socket URL always says localhost, so only the socket file tells two local servers apart.
    internal static func matches(saved: DatabaseConnection, parsed: ParsedConnectionURL) -> Bool {
        guard saved.type == parsed.type else { return false }
        if parsed.namesDatabaseFile {
            return localFilePath(of: saved) == parsed.database
        }
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: saved.type)
        if let endpoint = snapshot?.capabilities.serverEndpointFields, parsed.additionalFields[endpoint.hostFieldId] != nil {
            guard saved.activeServerEndpointFields != nil else { return false }
            return sharesServerFields(saved: saved, parsed: parsed, fields: snapshot?.connection.additionalConnectionFields ?? [])
        }
        guard saved.database == parsed.database,
              parsed.username.isEmpty || saved.username == parsed.username,
              saved.localSocketFile == parsed.localSocketFile
        else { return false }
        guard parsed.localSocketFile == nil else { return true }
        return saved.host == parsed.host && (parsed.port == nil || saved.port == parsed.port)
    }

    // A saved file connection keeps whatever host and port the form defaulted to, and DuckDB keeps its path in a
    // field of its own, falling back to `database` as its driver does. A row that dials a server, reads its file
    // over SSH, or hides its file field (a MotherDuck row keeps the path it had in Local File) opens no local file.
    private static func localFilePath(of saved: DatabaseConnection) -> String? {
        guard saved.activeServerEndpointFields == nil, !saved.opensRemoteDatabaseFile,
              !saved.opensRemoteDatabaseSession else { return nil }
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: saved.type)
        let field = snapshot?.capabilities.localFilePathField ?? .database
        if case .additionalField(let id) = field, let fields = snapshot?.connection.additionalConnectionFields,
           let pathField = fields.first(where: { $0.id == id }),
           !fields.isVisible(pathField, forValues: saved.additionalFields) {
            return nil
        }
        let path = saved.localFilePath(in: field)
        return path.isEmpty ? saved.database : path
    }

    // Such a row leaves the built-in host and database at placeholders, so the fields the link sets decide. TLS is left
    // out as on every other link, and a field the link leaves out matches any value, as a port does.
    private static func sharesServerFields(
        saved: DatabaseConnection,
        parsed: ParsedConnectionURL,
        fields: [ConnectionField]
    ) -> Bool {
        let tlsFieldIds = Set(fields.filter(DriverTLSMode.isModeField).map(\.id))
        return fields.allSatisfy { field in
            guard let linked = parsed.additionalFields[field.id],
                  !tlsFieldIds.contains(field.id), !tlsFieldIds.contains(field.visibleWhen?.fieldId ?? ""),
                  fields.isVisible(field, forValues: saved.additionalFields)
            else { return true }
            let stored = (saved.additionalFields[field.id] ?? "").trimmingCharacters(in: .whitespaces)
            return (stored.isEmpty ? (field.defaultValue ?? "") : stored) == linked
        }
    }
}
