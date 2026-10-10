//
//  MCPConnectionListEncoder.swift
//  TablePro
//

import Foundation

internal enum MCPConnectionListEncoder {
    internal static func encode(_ listings: [ExternalConnectionListing], access: ConnectionAccess) -> JsonValue {
        let entries = listings
            .filter { $0.aiPolicy != .never && access.allows($0.id) }
            .map(entry)
        return .object(["connections": .array(entries)])
    }

    internal static func entry(_ listing: ExternalConnectionListing) -> JsonValue {
        var fields: [String: JsonValue] = [
            "id": .string(listing.id.uuidString),
            "name": .string(listing.name),
            "type": .string(listing.databaseType),
            "host": .string(listing.host),
            "port": .int(listing.port),
            "database": .string(listing.database),
            "is_connected": .bool(listing.isConnected),
            "ai_policy": .string(listing.aiPolicy.rawValue),
            "external_access": .string(listing.externalAccess.rawValue),
            "safe_mode": .string(listing.safeModeLevel.rawValue),
            "tags": .array(listing.tags.map(tag))
        ]
        if let color = listing.color.externalName {
            fields["color"] = .string(color)
        }
        if let group = listing.group {
            fields["group"] = self.group(group)
        }
        return .object(fields)
    }

    private static func group(_ group: ExternalConnectionListing.Group) -> JsonValue {
        var fields: [String: JsonValue] = [
            "id": .string(group.id.uuidString),
            "name": .string(group.name),
            "path": .array(group.path.map { .string($0) })
        ]
        if let color = group.color.externalName {
            fields["color"] = .string(color)
        }
        return .object(fields)
    }

    private static func tag(_ tag: ExternalConnectionListing.Tag) -> JsonValue {
        var fields: [String: JsonValue] = [
            "id": .string(tag.id.uuidString),
            "name": .string(tag.name)
        ]
        if let color = tag.color.externalName {
            fields["color"] = .string(color)
        }
        return .object(fields)
    }
}
