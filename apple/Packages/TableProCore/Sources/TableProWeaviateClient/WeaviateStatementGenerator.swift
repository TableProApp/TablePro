import Foundation
import TableProWeaviateCore

public struct WeaviateCellChange: Sendable, Equatable {
    public let column: String
    public let newText: String?

    public init(column: String, newText: String?) {
        self.column = column
        self.newText = newText
    }
}

public struct WeaviateTrackedChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case insert
        case update
        case delete
    }

    public let kind: Kind
    public let uuid: String?
    public let values: [String: String?]
    public let cellChanges: [WeaviateCellChange]

    public init(
        kind: Kind,
        uuid: String?,
        values: [String: String?],
        cellChanges: [WeaviateCellChange]
    ) {
        self.kind = kind
        self.uuid = uuid
        self.values = values
        self.cellChanges = cellChanges
    }
}

public enum WeaviateSkipReason: String, Sendable, Equatable {
    case missingUUID
    case noEditableColumns
    case payloadNotEncodable
}

public struct WeaviateSkippedChange: Sendable, Equatable {
    public let kind: WeaviateTrackedChange.Kind
    public let reason: WeaviateSkipReason

    public init(kind: WeaviateTrackedChange.Kind, reason: WeaviateSkipReason) {
        self.kind = kind
        self.reason = reason
    }
}

/// A skipped change writes nothing while the grid reports the save succeeded, so the driver has to
/// be able to say what it dropped. Same reason the MongoDB generator logs its own skips.
public struct WeaviateWriteBatch: Sendable, Equatable {
    public let requests: [WeaviateWriteRequest]
    public let skipped: [WeaviateSkippedChange]

    public init(requests: [WeaviateWriteRequest], skipped: [WeaviateSkippedChange]) {
        self.requests = requests
        self.skipped = skipped
    }
}

public enum WeaviateStatementGenerator {
    public static func generate(
        collection: String,
        columns: [String],
        typeNames: [String],
        changes: [WeaviateTrackedChange]
    ) -> WeaviateWriteBatch {
        let types = Dictionary(zip(columns, typeNames), uniquingKeysWith: { first, _ in first })
        var requests: [WeaviateWriteRequest] = []
        var skipped: [WeaviateSkippedChange] = []
        for change in changes {
            let request: WeaviateWriteRequest?
            switch change.kind {
            case .insert:
                request = insert(collection: collection, types: types, change: change)
            case .update:
                request = update(collection: collection, types: types, change: change)
            case .delete:
                request = delete(collection: collection, change: change)
            }
            if let request {
                requests.append(request)
            } else {
                skipped.append(WeaviateSkippedChange(kind: change.kind, reason: reason(for: change)))
            }
        }
        return WeaviateWriteBatch(requests: requests, skipped: skipped)
    }

    private static func reason(for change: WeaviateTrackedChange) -> WeaviateSkipReason {
        if change.kind != .insert, change.uuid?.isEmpty ?? true {
            return .missingUUID
        }
        if change.kind == .update, editablePatch(from: change).isEmpty {
            return .noEditableColumns
        }
        return .payloadNotEncodable
    }

    private static func editablePatch(from change: WeaviateTrackedChange) -> [String: String?] {
        var patch: [String: String?] = [:]
        for cell in change.cellChanges where !WeaviateSchema.immutableColumns.contains(cell.column) {
            patch[cell.column] = cell.newText
        }
        return patch
    }

    private static func insert(
        collection: String,
        types: [String: String],
        change: WeaviateTrackedChange
    ) -> WeaviateWriteRequest? {
        var payload: [String: Any] = [
            "class": collection,
            "properties": properties(from: change.values, types: types)
        ]
        if let uuid = change.uuid, !uuid.isEmpty {
            payload["id"] = uuid
        }
        guard let body = try? WeaviateJSON.text(payload) else { return nil }
        return WeaviateWriteRequest(method: "POST", path: "/v1/objects", body: body)
    }

    private static func update(
        collection: String,
        types: [String: String],
        change: WeaviateTrackedChange
    ) -> WeaviateWriteRequest? {
        guard let uuid = change.uuid, !uuid.isEmpty else { return nil }
        let patch = editablePatch(from: change)
        guard !patch.isEmpty else { return nil }
        let payload: [String: Any] = [
            "class": collection,
            "properties": properties(from: patch, types: types)
        ]
        guard let body = try? WeaviateJSON.text(payload) else { return nil }
        return WeaviateWriteRequest(
            method: "PATCH",
            path: "/v1/objects/\(WeaviatePathEncoding.segment(uuid))",
            query: ["class": collection],
            body: body
        )
    }

    private static func delete(collection: String, change: WeaviateTrackedChange) -> WeaviateWriteRequest? {
        guard let uuid = change.uuid, !uuid.isEmpty else { return nil }
        return WeaviateWriteRequest(
            method: "DELETE",
            path: "/v1/objects/\(WeaviatePathEncoding.segment(uuid))",
            query: ["class": collection],
            body: nil
        )
    }

    private static func properties(from values: [String: String?], types: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (column, text) in values {
            if WeaviateSchema.immutableColumns.contains(column) { continue }
            if column.hasPrefix("\(WeaviateObjectCodec.additionalKey).") { continue }
            if let text {
                result[column] = WeaviateJSON.parsedValue(text, typeName: types[column] ?? "text")
            } else {
                result[column] = NSNull()
            }
        }
        return result
    }
}
