//
//  TeamLibraryFieldConflictSheet.swift
//  TablePro
//

import Foundation
import SwiftUI
import TableProFFI

// One team conflict as the sheet shows it: only the fields both sides changed, or, against a deletion, the fields the
// side that kept the item changed.
internal struct TeamLibraryFieldConflictPresentation: Equatable {
    enum Shape: Equatable {
        case bothChanged
        case youDeleted
        case teamDeleted
    }

    enum Value: Equatable {
        case text(String)
        case code(String)
        case empty
        case notSet
    }

    struct Row: Equatable, Identifiable {
        let field: String
        let label: String
        let mine: Value?
        let theirs: Value?

        var id: String { field }
    }

    let shape: Shape
    let title: String
    let message: String
    let rows: [Row]
    // Who last changed or deleted the team's copy; none when the server names no one to this account.
    let writer: String?

    init(conflict: TeamConflictInfo, teamName: String?, writer: String? = nil) {
        let mine = conflict.mine.map(Self.members)
        let theirs = conflict.theirs.map(Self.members)
        let name = TeamLibraryConflictText.name(
            Self.text(mine?["name"]) ?? Self.text(theirs?["name"]) ?? conflict.record.recordId
        )
        let team = teamName.map(TeamLibraryConflictText.name) ?? String(localized: "your team")
        self.writer = writer
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : TeamLibraryConflictText.name($0) }
        switch (mine, theirs) {
        case (nil, _):
            shape = .youDeleted
            title = String(format: String(localized: "“%@” changed after you deleted it"), name)
            message = String(
                format: String(localized: "Someone in %@ changed this item after you deleted it. Keep Mine deletes it, and Keep Theirs keeps the team's version."),
                team
            )
        case (_, nil):
            shape = .teamDeleted
            title = String(format: String(localized: "“%@” was deleted from the team library"), name)
            message = String(
                format: String(localized: "Someone in %@ deleted this item after you changed it. Keep Mine puts it back with your changes, and Keep Theirs leaves it deleted."),
                team
            )
        default:
            shape = .bothChanged
            title = String(format: String(localized: "“%@” changed since you last synced"), name)
            message = String(
                format: String(localized: "You and someone in %@ changed the same fields of this item. Choose the version the team library keeps."),
                team
            )
        }
        let kind = conflict.record.kind
        rows = Self.ordered(conflict.fields, kind: kind).map { field in
            Row(
                field: field,
                label: Self.label(of: field, kind: kind),
                mine: mine.map { Self.value(of: field, in: $0, kind: kind) },
                theirs: theirs.map { Self.value(of: field, in: $0, kind: kind) }
            )
        }
    }

    // The engine sends each side as the record's JSON object; anything else reads as an item with no fields.
    private static func members(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func value(of field: String, in members: [String: Any], kind: String) -> Value {
        guard let value = members[field], !(value is NSNull) else { return .notSet }
        if let text = value as? String {
            if text.isEmpty { return .empty }
            return codeFields(of: kind).contains(field)
                ? .code(TeamLibraryConflictText.visible(text, keepingLineBreaks: true))
                : .text(TeamLibraryConflictText.visible(text, keepingLineBreaks: false))
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? String(localized: "Yes") : String(localized: "No"))
            }
            return .text(number.stringValue)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return .notSet }
        return .code(TeamLibraryConflictText.visible(json, keepingLineBreaks: false))
    }

    // Known fields in the order the item's editor shows them, then any field a newer build wrote, by name.
    private static func ordered(_ fields: [String], kind: String) -> [String] {
        let known = knownOrder(of: kind)
        return fields.sorted { left, right in
            switch (known.firstIndex(of: left), known.firstIndex(of: right)) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
    }

    private static func knownOrder(of kind: String) -> [String] {
        switch kind {
        case "library_connection":
            [
                "name", "type", "host", "port", "database", "username", "sshConfig", "sshProfileId", "sslConfig",
                "safeModeLevel", "aiPolicy", "connectTimeoutSeconds", "queryTimeoutSeconds", "redisDatabase",
                "additionalFields", "color", "iconName", "localOnly", "startupCommands", "tunnelCommand"
            ]
        case "library_folder":
            ["name", "parent_client_id", "sort_order"]
        case "library_query":
            ["name", "keyword", "query", "folder_client_id", "connection_client_id", "sort_order"]
        default:
            []
        }
    }

    private static func codeFields(of kind: String) -> Set<String> {
        switch kind {
        case "library_connection": ["startupCommands"]
        case "library_query": ["query"]
        default: []
        }
    }

    // A field a newer build wrote keeps its wire name, which is a technical term.
    private static func label(of field: String, kind: String) -> String {
        switch (kind, field) {
        case (_, "name"): String(localized: "Name")
        case ("library_connection", "type"): String(localized: "Type")
        case ("library_connection", "host"): String(localized: "Host")
        case ("library_connection", "port"): String(localized: "Port")
        case ("library_connection", "database"): String(localized: "Database")
        case ("library_connection", "username"): String(localized: "User")
        case ("library_connection", "sshConfig"): String(localized: "SSH")
        case ("library_connection", "sshProfileId"): String(localized: "SSH Profile")
        case ("library_connection", "sslConfig"): String(localized: "SSL/TLS")
        case ("library_connection", "safeModeLevel"): String(localized: "Safe Mode")
        case ("library_connection", "aiPolicy"): String(localized: "AI Policy")
        case ("library_connection", "connectTimeoutSeconds"): String(localized: "Connect Timeout")
        case ("library_connection", "queryTimeoutSeconds"): String(localized: "Query Timeout")
        case ("library_connection", "redisDatabase"): String(localized: "Database Index")
        case ("library_connection", "additionalFields"): String(localized: "Driver Options")
        case ("library_connection", "color"): String(localized: "Color")
        case ("library_connection", "iconName"): String(localized: "Icon")
        case ("library_connection", "localOnly"): String(localized: "Local Only")
        case ("library_connection", "startupCommands"): String(localized: "Startup Commands")
        case ("library_connection", "tunnelCommand"): String(localized: "Tunnel Command")
        case ("library_folder", "parent_client_id"), ("library_query", "folder_client_id"): String(localized: "Folder")
        case ("library_query", "connection_client_id"): String(localized: "Connection")
        case ("library_query", "keyword"): String(localized: "Keyword")
        case ("library_query", "query"): "SQL"
        case (_, "sort_order"): String(localized: "Position")
        default: TeamLibraryConflictText.name(field)
        }
    }
}

// What other members wrote, as text that shows every character it holds. A directional control reorders what a value
// shows (CVE-2021-42574, "Trojan Source"), and a line break or control in a name can push the sheet's buttons away.
internal enum TeamLibraryConflictText {
    static let nameLimit = 80

    static func visible(_ text: String, keepingLineBreaks: Bool) -> String {
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if keepingLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                shown.append(scalar)
            } else if isHidden(scalar) {
                shown.append(contentsOf: "<U+\(String(format: "%04X", scalar.value))>".unicodeScalars)
            } else {
                shown.append(scalar)
            }
        }
        return String(shown)
    }

    // One line, cut at `nameLimit` characters.
    static func name(_ text: String) -> String {
        let shown = visible(text, keepingLineBreaks: false)
        guard shown.count > nameLimit else { return shown }
        return String(shown.prefix(nameLimit)) + "…"
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0x2028, 0x2029:
            true
        default:
            scalar.properties.generalCategory == .control
        }
    }
}

// Shown from the Team Library header, one conflict at a time, while the engine holds any.
internal struct TeamLibraryFieldConflictSheet: View {
    @ObservedObject var model: TeamLibraryConflictsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let conflict = model.conflicts.first {
                TeamLibraryFieldConflictContent(
                    presentation: TeamLibraryFieldConflictPresentation(
                        conflict: conflict,
                        teamName: model.teamName(of: conflict.record.scope),
                        writer: model.writer(of: conflict.record)
                    ),
                    remaining: model.conflicts.count,
                    isResolving: model.resolving != nil,
                    failure: model.failure(for: conflict.record),
                    decideLater: { dismiss() },
                    keep: { choice in
                        Task { await model.resolve(conflict, keep: choice) }
                    }
                )
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { dismiss() }
            }
        }
        .onValueChange(of: model.conflicts.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}

internal struct TeamLibraryFieldConflictContent: View {
    let presentation: TeamLibraryFieldConflictPresentation
    let remaining: Int
    let isResolving: Bool
    let failure: String?
    let decideLater: () -> Void
    let keep: (ConflictChoiceTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(presentation.message)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // A connection can differ in many fields: the rows scroll so the buttons stay on a small screen.
            GroupBox {
                ScrollView {
                    TeamLibraryConflictFieldGrid(presentation: presentation)
                        .padding(4)
                }
                .frame(maxHeight: 360)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("team-library-conflict-fields")

            if let writer = presentation.writer {
                LabeledContent(String(localized: "Changed By"), value: writer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("team-library-conflict-writer")
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("team-library-conflict-failure")
            }

            HStack(spacing: 8) {
                Button(String(localized: "Decide Later"), action: decideLater)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("team-library-conflict-later")
                if remaining > 1 {
                    Text(String(format: String(localized: "%d conflicts left"), remaining))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Saving your choice"))
                }
                Button(String(localized: "Keep Mine")) { keep(.keepMine) }
                    .accessibilityHint(Text(keepMineHint))
                    .accessibilityIdentifier("team-library-conflict-keep-mine")
                Button(String(localized: "Keep Theirs")) { keep(.keepTheirs) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Text(keepTheirsHint))
                    .accessibilityIdentifier("team-library-conflict-keep-theirs")
            }
            .disabled(isResolving)
        }
        .padding(20)
        .frame(width: 600)
    }

    private var keepMineHint: String {
        switch presentation.shape {
        case .bothChanged: String(localized: "Replaces the team's version with yours")
        case .youDeleted: String(localized: "Deletes the item from the team library")
        case .teamDeleted: String(localized: "Puts the item back with your changes")
        }
    }

    private var keepTheirsHint: String {
        switch presentation.shape {
        case .bothChanged, .youDeleted: String(localized: "Leaves the team's version as it is")
        case .teamDeleted: String(localized: "Leaves the item deleted")
        }
    }
}

// One row per field, with a column for each side that still holds the item.
private struct TeamLibraryConflictFieldGrid: View {
    let presentation: TeamLibraryFieldConflictPresentation

    private struct Column: Identifiable {
        let id: String
        let title: String
        let value: (TeamLibraryFieldConflictPresentation.Row) -> TeamLibraryFieldConflictPresentation.Value?
    }

    private var columns: [Column] {
        let mine = Column(id: "mine", title: String(localized: "Your Version")) { $0.mine }
        let theirs = Column(id: "theirs", title: String(localized: "Team's Version")) { $0.theirs }
        switch presentation.shape {
        case .bothChanged: return [mine, theirs]
        case .youDeleted: return [theirs]
        case .teamDeleted: return [mine]
        }
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(String(localized: "Field"))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                ForEach(columns) { column in
                    Text(column.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
            Divider()
            ForEach(presentation.rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 160, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    ForEach(columns) { column in
                        TeamLibraryConflictValueCell(value: column.value(row) ?? .notSet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                Text(column.title)
                                    + Text(verbatim: ", ")
                                    + Text(verbatim: TeamLibraryConflictValueCell.spoken(column.value(row) ?? .notSet))
                            )
                            .accessibilityIdentifier("team-library-conflict-\(column.id)-\(row.field)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TeamLibraryConflictValueCell: View {
    let value: TeamLibraryFieldConflictPresentation.Value

    static func spoken(_ value: TeamLibraryFieldConflictPresentation.Value) -> String {
        switch value {
        case .text(let text), .code(let text): text
        case .empty: String(localized: "Empty")
        case .notSet: String(localized: "Not set")
        }
    }

    var body: some View {
        switch value {
        case .text(let text):
            Text(text)
                .lineLimit(3)
                .textSelection(.enabled)
        case .code(let code):
            ScrollView {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        case .empty, .notSet:
            Text(Self.spoken(value))
                .foregroundStyle(.secondary)
        }
    }
}
