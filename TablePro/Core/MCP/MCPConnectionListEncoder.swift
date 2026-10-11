//
//  MCPConnectionListEncoder.swift
//  TablePro
//

import Foundation

internal enum MCPConnectionListPurpose: String, Sendable, CaseIterable {
    case agent
    case display
}

internal enum MCPConnectionListEncoder {
    /// `display` is for a launcher to show the user, so it keeps connections hidden from AI and adds
    /// the user name, but drops the policy fields an agent would act on.
    internal static func encode(
        _ listings: [ExternalConnectionListing],
        access: ConnectionAccess,
        purpose: MCPConnectionListPurpose = .agent
    ) -> JsonValue {
        let entries: [JsonValue]
        switch purpose {
        case .agent:
            entries = listings
                .filter { $0.aiPolicy != .never && access.allows($0.id) }
                .map(entry)
        case .display:
            entries = listings
                .filter { access.allows($0.id) }
                .map(displayEntry)
        }
        return .object(["connections": .array(entries)])
    }

    internal static func entry(_ listing: ExternalConnectionListing) -> JsonValue {
        var fields = labelFields(listing)
        fields["ai_policy"] = .string(listing.aiPolicy.rawValue)
        fields["external_access"] = .string(listing.externalAccess.rawValue)
        fields["safe_mode"] = .string(listing.safeModeLevel.rawValue)
        return .object(fields)
    }

    private static func displayEntry(_ listing: ExternalConnectionListing) -> JsonValue {
        var fields = labelFields(listing)
        fields["username"] = .string(listing.username)
        return .object(fields)
    }

    private static func labelFields(_ listing: ExternalConnectionListing) -> [String: JsonValue] {
        var fields: [String: JsonValue] = [
            "id": .string(listing.id.uuidString),
            "name": .string(listing.name),
            "type": .string(listing.databaseType),
            "host": .string(listing.host),
            "port": .int(listing.port),
            "database": .string(listing.database),
            "is_connected": .bool(listing.isConnected),
            "tags": .array(listing.tags.map(tag))
        ]
        if let color = listing.color.externalName {
            fields["color"] = .string(color)
        }
        if let group = listing.group {
            fields["group"] = self.group(group)
        }
        return fields
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
