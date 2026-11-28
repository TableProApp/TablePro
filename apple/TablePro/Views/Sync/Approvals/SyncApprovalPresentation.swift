//
//  SyncApprovalPresentation.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProFFI
import TableProPluginKit
import TableProSSHConfig

// What the Mac knows about the values a pulled record names: its profiles, its AI providers, each driver's traits as
// the connection form reads them, and this Mac's copy of a connection.
internal struct SyncApprovalLookup {
    var profileName: @MainActor (_ kind: String, _ id: String) -> String?
    var aiProviderName: @MainActor (_ id: String) -> String?
    // Nil for a driver this Mac has no metadata for.
    var traits: @MainActor (_ type: String) -> ConnectionTypeTraits?
    var connection: @MainActor (_ recordID: String) -> SyncApprovalConnectionState?

    static let none = SyncApprovalLookup(
        profileName: { _, _ in nil },
        aiProviderName: { _ in nil },
        traits: { _ in nil },
        connection: { _ in nil }
    )

    @MainActor static var live: SyncApprovalLookup {
        SyncApprovalLookup(
            profileName: { kind, id in
                guard let uuid = UUID(uuidString: id) else { return nil }
                switch kind {
                case "ssh_profile": return SSHProfileStorage.shared.profile(for: uuid)?.name
                case "credential_profile": return CredentialProfileStorage.shared.profile(for: uuid)?.name
                default: return nil
                }
            },
            aiProviderName: { id in
                AppSettingsManager.shared.ai.providers.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }?
                    .displayName
            },
            traits: { type in
                let databaseType = DatabaseType(rawValue: type)
                guard PluginMetadataRegistry.shared.snapshot(for: databaseType) != nil else { return nil }
                return ConnectionTypeTraits.live(for: databaseType, pluginManager: .shared)
            },
            connection: { recordID in
                guard let id = UUID(uuidString: recordID),
                      let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id })
                else { return nil }
                return SyncApprovalConnectionState(connection)
            }
        )
    }
}

// One record waiting for the person, in the words the connection form and Settings use. A value that signs in is
// never shown, though the core sends none: a driver field this Mac knows as secure reads as hidden.
internal struct SyncApprovalItem: Identifiable, Equatable {
    enum Value: Equatable {
        case text(String)
        case code(String)
        // A list of objects, one line per object with every member it holds, since the core approves the list whole.
        case lines([String])
        case notSet
        case hidden
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        // Nil for a record new to this Mac, which has no value of its own.
        let from: Value?
        let to: Value
    }

    let id: SyncRecordRef
    // The copy this item was built from, which a decision on it sends back.
    let record: RecordApprovalInfo
    let title: String
    let subtitle: String
    let symbolName: String
    let isNew: Bool
    let isTeam: Bool
    let rows: [Row]
}

@MainActor
internal enum SyncApprovalPresentation {
    static func items(_ records: [RecordApprovalInfo], lookup: SyncApprovalLookup) -> [SyncApprovalItem] {
        records.map { item($0, lookup: lookup, among: records) }
    }

    static func item(
        _ record: RecordApprovalInfo,
        lookup: SyncApprovalLookup,
        among records: [RecordApprovalInfo] = []
    ) -> SyncApprovalItem {
        let kind = record.record.kind
        let isConnection = kind == "connection" || kind == "library_connection"
        // This Mac's copy of a personal connection, with every value the pull brings laid over it. A new record has
        // only the pulled values; a team copy is the Team Library's, which this lookup does not read.
        var state = kind == "connection" && !record.newRecord
            ? lookup.connection(record.record.recordId) ?? SyncApprovalConnectionState()
            : SyncApprovalConnectionState()
        for field in record.fields {
            state.apply(path(of: field.field, kind: kind), field.pulled.flatMap(parse))
        }
        var traits: ConnectionTypeTraits?
        if isConnection, let type = state.type {
            traits = lookup.traits(type)
        }
        let sshProfileResolves = state.sshProfileId.map { lookup.profileName("ssh_profile", $0) != nil } ?? false
        let context = Context(
            kind: kind,
            state: state,
            traits: traits,
            lookup: lookup,
            pendingNames: Dictionary(
                records.compactMap { other in other.name.map { (other.record.recordId.lowercased(), $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        )
        let rows = record.fields.compactMap { field -> SyncApprovalItem.Row? in
            let parts = Self.path(of: field.field, kind: kind)
            if record.newRecord, !setsSomething(field.pulled, at: parts, context: context) {
                return nil
            }
            if isConnection,
               !SyncApprovalVisibility.shows(parts, state: state, traits: traits, sshProfileResolves: sshProfileResolves) {
                return nil
            }
            return SyncApprovalItem.Row(
                id: field.field,
                label: label(of: parts, context: context),
                from: record.newRecord ? nil : value(field.current, at: parts, context: context),
                to: value(field.pulled, at: parts, context: context)
            )
        }
        return SyncApprovalItem(
            id: record.record,
            record: record,
            title: title(of: record),
            subtitle: subtitle(kind: kind, isNew: record.newRecord),
            symbolName: symbolName(of: record),
            isNew: record.newRecord,
            isTeam: record.record.scope.hasPrefix("team"),
            rows: distinctLabels(order(rows, kind: kind), kind: kind)
        )
    }

    // MARK: - Record

    private static func title(of record: RecordApprovalInfo) -> String {
        guard let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return String(localized: "Unnamed")
        }
        if isSettings(record.record.kind) {
            return SettingsPane(rawValue: name)?.title ?? TeamLibraryConflictText.name(name)
        }
        return TeamLibraryConflictText.name(name)
    }

    static func subtitle(kind: String, isNew: Bool) -> String {
        switch (kind, isNew) {
        case ("connection", true): String(localized: "New connection")
        case ("connection", false): String(localized: "Changed connection")
        case ("library_connection", true): String(localized: "New Team Library connection")
        case ("library_connection", false): String(localized: "Changed Team Library connection")
        case ("ssh_profile", true): String(localized: "New SSH profile")
        case ("ssh_profile", false): String(localized: "Changed SSH profile")
        case ("credential_profile", true): String(localized: "New credential profile")
        case ("credential_profile", false): String(localized: "Changed credential profile")
        case (_, true) where isSettings(kind): String(localized: "New settings")
        case (_, false) where isSettings(kind): String(localized: "Changed settings")
        case (_, true): String(localized: "New item")
        case (_, false): String(localized: "Changed item")
        }
    }

    private static func symbolName(of record: RecordApprovalInfo) -> String {
        switch record.record.kind {
        case "connection", "library_connection": return "cylinder.split.1x2"
        case "ssh_profile": return "terminal"
        case "credential_profile": return "person.badge.key"
        case let kind where isSettings(kind):
            return record.name.flatMap(SettingsPane.init(rawValue:))?.symbol ?? "gearshape"
        default: return "doc"
        }
    }

    private static func isSettings(_ kind: String) -> Bool {
        kind.hasSuffix("_settings")
    }

    // MARK: - Fields

    private struct Context {
        let kind: String
        let state: SyncApprovalConnectionState
        let traits: ConnectionTypeTraits?
        let lookup: SyncApprovalLookup
        // Names of the records waiting beside this one, so a profile that arrives with its connection reads by name.
        let pendingNames: [String: String]
    }

    // A JSON Pointer (RFC 6901), in the personal kinds' snake case: the team library keeps its camel case keys, and a
    // driver field's id stays as written.
    static func path(of pointer: String, kind: String) -> [String] {
        var parts = pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { part in
            part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        guard kind.hasPrefix("library_") else { return parts }
        for index in parts.indices {
            if index > 0, ["additional_fields", "options"].contains(parts[index - 1]) { break }
            parts[index] = snakeCase(parts[index])
        }
        return parts
    }

    private static func snakeCase(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase {
                out += "_" + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func label(of path: [String], context: Context) -> String {
        guard let head = path.first else { return String(localized: "Unnamed") }
        if isSettings(context.kind) {
            return settingsLabel(path)
        }
        switch context.kind {
        case "ssh_profile":
            return sshProfileLabel(head) ?? verbatim(path)
        case "credential_profile":
            switch head {
            case "username": return String(localized: "Username")
            case "password_mode": return String(localized: "Password")
            default: return verbatim(path)
            }
        default:
            return connectionLabel(path, context: context)
        }
    }

    private static func connectionLabel(_ path: [String], context: Context) -> String {
        let sub = path.count > 1 ? path[1] : nil
        switch path[0] {
        case "type": return String(localized: "Type")
        case "host": return String(localized: "Host")
        case "port": return String(localized: "Port")
        // A file driver keeps its path there, which its form calls File Path.
        case "database":
            return context.traits?.connectionMode == .fileBased ? String(localized: "File Path") : String(localized: "Database")
        case "username": return String(localized: "Username")
        case "safe_mode_level": return String(localized: "Safe Mode")
        case "ai_policy": return String(localized: "AI Policy")
        case "ai_rules": return String(localized: "AI Rules")
        case "ai_always_allowed_tools": return String(localized: "AI Tools Always Allowed")
        case "startup_commands": return String(localized: "Startup Commands")
        case "redis_database": return String(localized: "Database Index")
        case "ssh_profile_id": return String(localized: "SSH Profile")
        case "credential_profile_id": return String(localized: "Credential Profile")
        case "external_access": return String(localized: "External Clients")
        case "auth_mode": return String(localized: "Authentication")
        case "ssh_route": return String(localized: "SSH Route")
        case "credential_reference": return String(localized: "Password Source")
        case "ssh_config":
            switch sub {
            case "enabled": return String(localized: "SSH Tunnel")
            case "host": return String(localized: "SSH Host")
            case "port": return String(localized: "SSH Port")
            case "username": return String(localized: "SSH User")
            case "auth_method": return String(localized: "SSH Authentication")
            case "private_key_path": return String(localized: "Private Key")
            case "agent_socket_path": return String(localized: "Agent Socket")
            case "jump_hosts": return String(localized: "Jump Hosts")
            case "remote_file_access": return String(localized: "Remote File Access")
            case "remote_file_path": return String(localized: "Remote File")
            default: return String(localized: "SSH Tunnel")
            }
        case "ssl_config":
            switch sub {
            case "mode": return String(localized: "SSL Mode")
            case "ca_certificate_path": return String(localized: "CA Certificate")
            case "client_certificate_path": return String(localized: "Client Certificate")
            case "client_key_path": return String(localized: "Client Key")
            case "server_name": return String(localized: "TLS Server Name")
            default: return String(localized: "SSL/TLS")
            }
        case "network_options":
            switch sub {
            case "dns_seed_list": return String(localized: "DNS Seed List")
            case "auth_database": return String(localized: "Authentication Database")
            case "replica_set": return String(localized: "Replica Set")
            case "more_hosts": return String(localized: "Hosts")
            case "channel_binding": return String(localized: "Channel Binding")
            default: return String(localized: "Connection Options")
            }
        case "additional_fields":
            guard let id = sub else { return verbatim(path) }
            return context.traits?.field(id)?.label ?? visible(id)
        default:
            return verbatim(path)
        }
    }

    private static func sshProfileLabel(_ key: String) -> String? {
        switch key {
        case "host": String(localized: "Host")
        case "port": String(localized: "Port")
        case "username": String(localized: "Username")
        case "auth_method": String(localized: "Authentication")
        case "private_key_path": String(localized: "Private Key")
        case "agent_socket_path": String(localized: "Agent Socket")
        case "jump_hosts": String(localized: "Jump Hosts")
        default: nil
        }
    }

    // The words of the Settings control that sets the option; one with none here keeps its key, a technical name.
    private static func settingsLabel(_ path: [String]) -> String {
        let key = path.count > 1 && path[0] == "options" ? path[1] : path[0]
        switch key {
        case "enabled": return String(localized: "Enable AI features")
        case "providers": return String(localized: "Providers")
        case "activeProviderID": return String(localized: "Active provider")
        case "inlineSuggestionsEnabled": return String(localized: "Suggest SQL while typing")
        case "useAppleIntelligence": return AppleIntelligenceAvailability.displayName
        case "includeSchema": return String(localized: "Include database schema")
        case "includeCurrentQuery": return String(localized: "Include current query")
        case "includeQueryResults": return String(localized: "Include query results")
        case "maxSchemaTables": return String(localized: "Maximum tables")
        case "maxToolRoundtrips": return String(localized: "Tool call limit")
        case "maxToolRoundtripsEnabled": return String(localized: "Limit tool calls per reply")
        case "defaultConnectionPolicy": return String(localized: "Default AI policy")
        case "chatMode": return String(localized: "Chat mode")
        case "shareAnalytics": return String(localized: "Share usage data")
        default: return visible(key)
        }
    }

    // Two rows of a record never read alike: a label that repeats also names each row's member, a technical name.
    private static func distinctLabels(_ rows: [SyncApprovalItem.Row], kind: String) -> [SyncApprovalItem.Row] {
        let counts = Dictionary(rows.map { ($0.label, 1) }, uniquingKeysWith: +)
        return rows.map { row in
            guard counts[row.label, default: 0] > 1 else { return row }
            let member = visible(path(of: row.id, kind: kind).last ?? row.id)
            return SyncApprovalItem.Row(
                id: row.id,
                label: String(format: String(localized: "%1$@ (%2$@)"), row.label, member),
                from: row.from,
                to: row.to
            )
        }
    }

    // A key the Mac has no words for came from the pull, so it shows every character it holds, as a value does.
    private static func verbatim(_ path: [String]) -> String {
        visible(path.joined(separator: "."))
    }

    // Destination first, then how it signs in, then what runs and what AI may do, as the connection form orders them.
    private static func order(_ rows: [SyncApprovalItem.Row], kind: String) -> [SyncApprovalItem.Row] {
        let known = [
            "type", "host", "port", "database", "username", "auth_mode", "credential_profile_id", "credential_reference",
            "redis_database", "network_options", "additional_fields", "ssh_profile_id", "ssh_config", "ssh_route",
            "ssl_config", "safe_mode_level", "startup_commands", "external_access", "ai_policy", "ai_rules",
            "ai_always_allowed_tools", "auth_method", "private_key_path", "agent_socket_path", "jump_hosts",
            "password_mode", "options"
        ]
        func rank(_ row: SyncApprovalItem.Row) -> Int {
            path(of: row.id, kind: kind).first.flatMap { known.firstIndex(of: $0) } ?? known.count
        }
        return rows.enumerated().sorted { left, right in
            let (leftRank, rightRank) = (rank(left.element), rank(right.element))
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    // MARK: - Values

    // Nothing to show for a new record: no value, an empty one, or a switch left off. A driver field reads by its value.
    private static func setsSomething(_ json: String?, at path: [String], context: Context) -> Bool {
        if path.first == "additional_fields", path.count == 2 {
            guard let text = SyncApprovalVisibility.entryValue(json.flatMap(parse)), !text.isEmpty else { return false }
            if case .toggle? = context.traits?.field(path[1])?.fieldType {
                return text == "true"
            }
            return true
        }
        return setsSomething(json)
    }

    static func setsSomething(_ json: String?) -> Bool {
        guard let json, let value = parse(json) else { return false }
        switch value {
        case is NSNull: return false
        case let text as String: return !text.isEmpty
        case let number as NSNumber where isBool(number): return number.boolValue
        case let list as [Any]: return !list.isEmpty
        case let object as [String: Any]: return !object.isEmpty
        default: return true
        }
    }

    private static func parse(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func value(_ json: String?, at path: [String], context: Context) -> SyncApprovalItem.Value {
        if path.first == "additional_fields", path.count == 2 {
            return driverValue(json, id: path[1], context: context)
        }
        guard let json, let parsed = parse(json), !(parsed is NSNull) else { return .notSet }
        let key = isSettings(context.kind) ? path.last ?? "" : path.joined(separator: "/")
        switch parsed {
        case let number as NSNumber where isBool(number):
            return .text(number.boolValue ? String(localized: "On") : String(localized: "Off"))
        case let number as NSNumber:
            return .text(number.stringValue)
        case let text as String:
            return text.isEmpty ? .notSet : textValue(text, key: key, context: context)
        case let list as [Any]:
            return listValue(list, key: key, context: context)
        default:
            return code(parsed)
        }
    }

    // In the words the form shows it in: a choice by its label, a switch On or Off, and a field left unset at the
    // driver's default, which is what the form shows and the connection uses.
    private static func driverValue(_ json: String?, id: String, context: Context) -> SyncApprovalItem.Value {
        let field = context.traits?.field(id)
        let given = SyncApprovalVisibility.entryValue(json.flatMap(parse)).flatMap { $0.isEmpty ? nil : $0 }
        if isSecret(id, value: given ?? "", field: field) {
            return .hidden
        }
        guard let text = given ?? field?.defaultValue, !text.isEmpty else { return .notSet }
        switch field?.fieldType {
        case .dropdown(let options)?:
            return .text(visible(options.first { $0.value == text }?.label ?? text))
        case .toggle?:
            return .text(text == "true" ? String(localized: "On") : String(localized: "Off"))
        default:
            return .text(visible(text))
        }
    }

    private static func isSecret(_ id: String, value: String, field: ConnectionField?) -> Bool {
        ConnectionFieldCatalog.trust(of: id) == .secret
            || ConnectionSecretOptions.isSecret(key: id, value: value)
            || field?.isSecure == true
    }

    private static func textValue(_ text: String, key: String, context: Context) -> SyncApprovalItem.Value {
        switch key {
        case "startup_commands", "ai_rules":
            return .code(TeamLibraryConflictText.visible(text, keepingLineBreaks: true))
        case "safe_mode_level":
            return .text(SafeModeLevel(wireValue: text, isReadOnly: false).displayName)
        case "ai_policy", "defaultConnectionPolicy":
            return .text(AIConnectionPolicy(rawValue: text)?.displayName ?? visible(text))
        case "external_access":
            return .text(ExternalAccessLevel(rawValue: text)?.displayName ?? visible(text))
        case "chatMode":
            return .text(AIChatMode(rawValue: text)?.displayName ?? visible(text))
        case "ssh_config/auth_method", "auth_method":
            return .text(SSHAuthMethod(rawValue: text)?.displayName ?? visible(text))
        case "ssh_profile_id":
            return .text(name(ofProfile: "ssh_profile", id: text, context: context))
        case "credential_profile_id":
            return .text(name(ofProfile: "credential_profile", id: text, context: context))
        case "activeProviderID":
            return .text(context.lookup.aiProviderName(text).map(visible) ?? visible(text))
        default:
            return .text(visible(text))
        }
    }

    private static func name(ofProfile kind: String, id: String, context: Context) -> String {
        let name = context.lookup.profileName(kind, id) ?? context.pendingNames[id.lowercased()]
        return name.map(TeamLibraryConflictText.name) ?? String(localized: "A profile not on this Mac")
    }

    private static func listValue(_ list: [Any], key: String, context: Context) -> SyncApprovalItem.Value {
        if list.isEmpty {
            return .text(String(localized: "None"))
        }
        if let texts = list as? [String] {
            return .text(visible(texts.joined(separator: ", ")))
        }
        guard let objects = list as? [[String: Any]] else { return code(list) }
        return .lines(objects.map { object in members(of: object, key: key) })
    }

    // Every member but the item's own id, known ones first in the words their editor uses, so a change to any of them
    // shows: the core applies the list whole.
    private static func members(of object: [String: Any], key: String) -> String {
        let known: [(key: String, label: String)]
        switch key {
        case "ssh_config/jump_hosts", "jump_hosts":
            known = [
                ("username", String(localized: "Username")),
                ("host", String(localized: "Host")),
                ("port", String(localized: "Port")),
                ("auth_method", String(localized: "Authentication")),
                ("authMethod", String(localized: "Authentication")),
                ("private_key_path", String(localized: "Private Key")),
                ("privateKeyPath", String(localized: "Private Key"))
            ]
        case "providers":
            known = [
                ("name", String(localized: "Name")),
                ("type", String(localized: "Type")),
                ("endpoint", String(localized: "Endpoint")),
                ("model", String(localized: "Model")),
                ("telemetryEnabled", String(localized: "Send telemetry to GitHub")),
                ("maxOutputTokens", String(localized: "Max output tokens")),
                ("reasoningEffort", String(localized: "Reasoning"))
            ]
        default:
            known = []
        }
        let rest = object.keys.filter { name in name != "id" && !known.contains { $0.key == name } }.sorted()
        let pairs = known.compactMap { entry in object[entry.key].map { (entry.label, member($0, key: entry.key)) } }
            + rest.map { name in (visible(name), member(object[name] as Any, key: name)) }
        return pairs.map { String(format: String(localized: "%1$@: %2$@"), $0.0, $0.1) }.joined(separator: ", ")
    }

    private static func member(_ value: Any, key: String) -> String {
        switch value {
        case is NSNull:
            return String(localized: "Not set")
        case let number as NSNumber where isBool(number):
            return number.boolValue ? String(localized: "On") : String(localized: "Off")
        case let number as NSNumber:
            return number.stringValue
        case let text as String where key == "type":
            return AIProviderType(rawValue: text)?.displayName ?? visible(text)
        case let text as String where key == "auth_method" || key == "authMethod":
            return SSHAuthMethod(rawValue: text)?.displayName ?? visible(text)
        case let text as String:
            return text.isEmpty ? String(localized: "Empty") : visible(text)
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return String(localized: "Not set") }
            return String(bytes: data, encoding: .utf8).map(visible) ?? String(localized: "Not set")
        }
    }

    private static func code(_ value: Any) -> SyncApprovalItem.Value {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return .notSet }
        guard let json = String(bytes: data, encoding: .utf8) else { return .notSet }
        return .code(TeamLibraryConflictText.visible(json, keepingLineBreaks: false))
    }

    private static func visible(_ text: String) -> String {
        TeamLibraryConflictText.visible(text, keepingLineBreaks: false)
    }

    // MARK: - Counts

    // The status line, the Welcome window and the sheet say it the same way. Two keys rather than inflection markup,
    // which reads verbatim when a catalog lacks it.
    nonisolated static func waitingLine(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 change needs your approval")
            : String(format: String(localized: "%lld changes need your approval"), Int64(count))
    }

    nonisolated static func approvingLine(_ count: Int) -> String {
        count == 1
            ? String(localized: "Approving 1 change…")
            : String(format: String(localized: "Approving %lld changes…"), Int64(count))
    }

    // MARK: - Spoken

    static func spoken(_ value: SyncApprovalItem.Value) -> String {
        switch value {
        case .text(let text), .code(let text): text
        case .lines(let lines): lines.joined(separator: "; ")
        case .notSet: String(localized: "Not set")
        case .hidden: String(localized: "Hidden")
        }
    }

    // What VoiceOver reads for one field: its label and the change, never only the new value.
    static func spoken(_ row: SyncApprovalItem.Row) -> String {
        guard let from = row.from else {
            return String(format: String(localized: "%1$@: %2$@"), row.label, spoken(row.to))
        }
        return String(format: String(localized: "%1$@, from %2$@ to %3$@"), row.label, spoken(from), spoken(row.to))
    }
}
