import Foundation

// Update rewrites only how an entry reaches TablePro; other catalog members are added only when missing, never widening a user's limit.
enum MCPEntryUpdate {
    static let commandKeys = ["command", "cmd"]
    static let urlKeys = ["url", "serverUrl", "httpUrl", "uri"]

    private static let alwaysWritten: Set<String> = ["type", "args"]
    private static let placeholders: Set<String> = ["command", "url", "authorization", "name"]

    private enum Transport {
        case command
        case url
    }

    enum Plan: Equatable {
        case replace(JSONValue)
        case merge(JSONValue)
    }

    static func plan(existing: JSONValue?, entry: JSONValue, template: JSONValue) -> Plan {
        guard let existing, case .object(let current) = existing, case .object(let wanted) = entry else { return .replace(entry) }
        if let had = transport(of: existing), let have = transport(of: entry), had != have {
            // A merge would leave the old transport's members behind; the user's choices still carry over.
            return .replace(.object(wanted.map { part in
                guard !alwaysWritten.contains(part.key), !holdsPlaceholder(template[part.key]),
                      let mine = existing[part.key] else { return part }
                return (key: part.key, value: mine)
            }))
        }
        return .merge(.object(overlay(current, with: wanted, template: template, alwaysWritten: alwaysWritten)))
    }

    private static func overlay(
        _ current: [(key: String, value: JSONValue)],
        with wanted: [(key: String, value: JSONValue)],
        template: JSONValue?,
        alwaysWritten: Set<String>
    ) -> [(key: String, value: JSONValue)] {
        var members = current
        for part in wanted {
            guard let position = members.firstIndex(where: { $0.key == part.key }) else {
                members.append(part)
                continue
            }
            let partTemplate = template?[part.key]
            if alwaysWritten.contains(part.key) {
                members[position].value = part.value
            } else if holdsPlaceholder(partTemplate) {
                if case .object(let inner) = members[position].value, case .object(let innerWanted) = part.value {
                    members[position].value = .object(overlay(inner, with: innerWanted, template: partTemplate, alwaysWritten: []))
                } else {
                    members[position].value = part.value
                }
            }
        }
        return members
    }

    private static func transport(of entry: JSONValue) -> Transport? {
        if commandKeys.contains(where: { entry[$0] != nil }) { return .command }
        if urlKeys.contains(where: { entry[$0] != nil }) { return .url }
        return nil
    }

    static func holdsPlaceholder(_ template: JSONValue?) -> Bool {
        switch template {
        case .string(let text)?:
            return placeholderNames(in: text).contains { placeholders.contains($0) }
        case .array(let items)?:
            return items.contains { holdsPlaceholder($0) }
        case .object(let members)?:
            return members.contains { holdsPlaceholder($0.value) }
        default:
            return false
        }
    }

    private static func placeholderNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let expression = rest[rest.index(after: open)..<close]
            names.append(String(expression.split(separator: "|", omittingEmptySubsequences: false).first ?? ""))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }
}
