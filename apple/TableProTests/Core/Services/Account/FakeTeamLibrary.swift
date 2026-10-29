//
//  FakeTeamLibrary.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport

// GET and POST /v2/teams/{team_id}/library/changes as tablepro-cloud's library use cases answer them: a seat reads, an
// owner or admin writes, items are keyed by kind and the client ID exactly as sent, and every write takes the next
// revision.
struct FakeTeamLibrary: Sendable {
    struct Item: Sendable {
        var kind: String
        var clientID: String
        var version: Int
        var revision: Int
        // The item's JSON object, nil for a tombstone.
        var json: Data?
        var deleted: Bool
        var updatedBy: String
        var via: String

        var data: [String: Any]? {
            json.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    var items: [String: [Item]] = [:]
    var revision = 0
    // A cursor that covers less than this answers 410 cursor_expired.
    var floor: [String: Int] = [:]
    var pageSize = 500
    // Answered, one per pull or per push, before anything else.
    var faults: [Int] = []
    var pushFaults: [Int] = []
    var pushCursorOffset = 0
    // Hold each pull or push until the test opens it.
    var pullGate: AsyncGate?
    var pushGate: AsyncGate?
    // A push holding a change whose data names this query is refused with 422 at that change, as the server does.
    var refusedQueryName: String?

    func live(_ team: String) -> [Item] {
        (items[team] ?? []).filter { !$0.deleted }
    }

    func item(_ team: String, kind: String, clientID: String) -> Item? {
        items[team]?.first { $0.kind == kind && $0.clientID == clientID }
    }

    // What another writer's push, the portal or an old build's /v1 publish leaves.
    mutating func write(
        _ team: String,
        kind: String,
        clientID: String,
        data: [String: Any]?,
        by account: String = "acct_other",
        via: String = "v2"
    ) {
        revision += 1
        let json = data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        var list = items[team] ?? []
        if let index = list.firstIndex(where: { $0.kind == kind && $0.clientID == clientID }) {
            list[index].version += 1
            list[index].revision = revision
            list[index].json = json
            list[index].deleted = data == nil
            list[index].updatedBy = account
            list[index].via = via
        } else {
            list.append(Item(
                kind: kind, clientID: clientID, version: 1, revision: revision, json: json,
                deleted: data == nil, updatedBy: account, via: via
            ))
        }
        items[team] = list
    }

    // MARK: - Pull

    mutating func pull(path: String, memberships: [[String: Any]]) -> (HTTPResponse, HTTPBody?) {
        if !faults.isEmpty {
            let status = faults.removeFirst()
            return FakeAccountServer.problem(status: status, code: status == 429 ? "rate_limited" : "internal")
        }
        guard let components = URLComponents(string: "http://fake\(path)"),
              let team = Self.team(in: components.path)
        else { return FakeAccountServer.problem(status: 404, code: "not_found") }
        guard let member = Self.member(team, in: memberships) else {
            return FakeAccountServer.problem(status: 404, code: "not_found")
        }
        guard member.hasSeat else { return FakeAccountServer.problem(status: 403, code: "forbidden") }
        let query = components.queryItems ?? []
        let limit = min(Int(query.first { $0.name == "limit" }?.value ?? "") ?? 500, pageSize)
        let cursorText = query.first { $0.name == "cursor" }?.value
        let all = (items[team] ?? []).sorted { $0.revision < $1.revision }
        let horizon = all.map(\.revision).max() ?? 0

        var page: [Item]
        var cursor: String
        var hasMore: Bool
        if let cursorText {
            guard let parsed = Self.parse(cursorText) else {
                return FakeAccountServer.problem(status: 422, code: "validation_failed")
            }
            if (parsed.end ?? parsed.after) < floor[team, default: 0] {
                return FakeAccountServer.problem(status: 410, code: "cursor_expired")
            }
            if let end = parsed.end {
                (page, cursor, hasMore) = snapshot(all, after: parsed.after, end: end, limit: limit, horizon: horizon)
            } else {
                let changed = all.filter { $0.revision > parsed.after }
                page = Array(changed.prefix(limit))
                hasMore = changed.count > limit
                cursor = "r\(page.last?.revision ?? parsed.after)"
            }
        } else {
            (page, cursor, hasMore) = snapshot(all, after: 0, end: horizon, limit: limit, horizon: horizon)
        }
        return FakeAccountServer.json(status: .ok, [
            "changes": page.map(Self.change), "cursor": cursor, "has_more": hasMore
        ])
    }

    private func snapshot(_ all: [Item], after: Int, end: Int, limit: Int, horizon: Int) -> ([Item], String, Bool) {
        let live = all.filter { !$0.deleted && $0.revision > after && $0.revision <= end }
        guard live.count <= limit else {
            let page = Array(live.prefix(limit))
            return (page, "s\(page.last?.revision ?? after):\(end)", true)
        }
        return (live, "r\(end)", horizon > end)
    }

    // MARK: - Push

    mutating func push(path: String, body: Data, memberships: [[String: Any]]) -> (HTTPResponse, HTTPBody?) {
        if !pushFaults.isEmpty {
            let status = pushFaults.removeFirst()
            return FakeAccountServer.problem(status: status, code: status == 429 ? "rate_limited" : "internal")
        }
        guard let team = Self.team(in: path), let member = Self.member(team, in: memberships) else {
            return FakeAccountServer.problem(status: 404, code: "not_found")
        }
        guard member.hasSeat else { return FakeAccountServer.problem(status: 403, code: "forbidden") }
        guard member.role == "owner" || member.role == "admin" else {
            return FakeAccountServer.problem(status: 403, code: "library_write_forbidden")
        }
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let changes = parsed?["changes"] as? [[String: Any]] ?? []
        guard !changes.isEmpty, changes.count <= 500 else {
            return FakeAccountServer.problem(status: 422, code: "validation_failed")
        }
        for (index, change) in changes.enumerated() {
            let data = change["data"] as? [String: Any]
            if let data, Self.holdsSecret(data) || refusedQueryName.map({ data["name"] as? String == $0 }) == true {
                return FakeAccountServer.json(status: .init(code: 422), contentType: "application/problem+json", [
                    "type": "https://api.tablepro.app/problems/validation_failed", "title": "validation failed",
                    "status": 422, "code": "validation_failed",
                    "errors": [["location": "body.changes[\(index)].data.query", "message": "refused"]]
                ])
            }
        }
        var results: [[String: Any]] = []
        for change in changes {
            results.append(apply(change, team: team))
        }
        let horizon = (items[team] ?? []).map(\.revision).max() ?? 0
        return FakeAccountServer.json(status: .ok, [
            "results": results, "cursor": "r\(horizon + pushCursorOffset)"
        ])
    }

    private mutating func apply(_ change: [String: Any], team: String) -> [String: Any] {
        let kind = change["kind"] as? String ?? ""
        let clientID = change["client_id"] as? String ?? ""
        let isDelete = change["op"] as? String == "delete"
        let base = change["base_version"] as? Int
        var result: [String: Any] = ["kind": kind, "client_id": clientID]
        let stored = item(team, kind: kind, clientID: clientID)

        if isDelete, stored == nil || stored?.deleted == true {
            result["status"] = "applied"
            result["version"] = stored?.version ?? 0
            return result
        }
        let inserts = stored == nil && base == nil
        let updates = stored != nil && base == stored?.version
        guard inserts || updates else {
            result["status"] = "conflict"
            result["version"] = stored?.version ?? 0
            if let stored {
                result["current"] = Self.change(stored)
            }
            return result
        }
        write(team, kind: kind, clientID: clientID, data: isDelete ? nil : change["data"] as? [String: Any] ?? [:], by: "acct_test")
        result["status"] = "applied"
        result["version"] = item(team, kind: kind, clientID: clientID)?.version ?? 0
        return result
    }

    // MARK: - Helpers

    static func change(_ item: Item) -> [String: Any] {
        var change: [String: Any] = [
            "kind": item.kind, "client_id": item.clientID, "version": item.version, "deleted": item.deleted,
            "updated_at": "2026-10-29T09:00:00Z", "updated_by": item.updatedBy
        ]
        if let data = item.data, !item.deleted {
            change["data"] = data
        }
        return change
    }

    private static func team(in path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 4, parts[0] == "teams", parts[2] == "library" else { return nil }
        return String(parts[1])
    }

    private static func member(_ team: String, in memberships: [[String: Any]]) -> (role: String, hasSeat: Bool)? {
        for membership in memberships {
            guard let ref = membership["team"] as? [String: Any], ref["id"] as? String == team else { continue }
            return (membership["role"] as? String ?? "", membership["has_seat"] as? Bool ?? false)
        }
        return nil
    }

    private static func parse(_ cursor: String) -> (after: Int, end: Int?)? {
        if cursor.hasPrefix("r"), let after = Int(cursor.dropFirst()) {
            return (after, nil)
        }
        let parts = cursor.dropFirst().split(separator: ":")
        guard cursor.hasPrefix("s"), parts.count == 2, let after = Int(parts[0]), let end = Int(parts[1]) else { return nil }
        return (after, end)
    }

    private static func holdsSecret(_ value: Any) -> Bool {
        switch value {
        case let object as [String: Any]:
            return object.contains { TeamLibraryPayload.isSecretKey($0.key) || holdsSecret($0.value) }
        case let array as [Any]:
            return array.contains { holdsSecret($0) }
        default:
            return false
        }
    }
}
