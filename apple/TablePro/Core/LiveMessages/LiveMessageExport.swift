//
//  LiveMessageExport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The columns a kind shows, and the same columns as text for Copy and Export.
internal enum LiveMessageExport {
    enum Column: CaseIterable {
        case time, channel, pattern, partition, offset, key, payload

        var title: String {
            switch self {
            case .time: String(localized: "Time")
            case .channel: String(localized: "Channel")
            case .pattern: String(localized: "Pattern")
            case .partition: String(localized: "Partition")
            case .offset: String(localized: "Offset")
            case .key: String(localized: "Key")
            case .payload: String(localized: "Payload")
            }
        }
    }

    static func columns(for kind: PluginLiveMessageKind) -> [Column] {
        switch kind {
        case .pubSub: [.time, .channel, .pattern, .payload]
        case .topics: [.time, .channel, .partition, .offset, .key, .payload]
        case .notifications: [.time, .channel, .payload]
        @unknown default: [.time, .channel, .payload]
        }
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }

    static func value(of column: Column, in entry: LiveMessageEntry) -> String {
        guard let message = entry.message else {
            guard case .gap(let reason) = entry.kind else { return "" }
            switch column {
            case .channel: return String(localized: "Connection lost")
            case .payload: return reason
            default: return ""
            }
        }
        switch column {
        case .time: return timeText(message.timestamp)
        case .channel: return message.channel
        case .pattern: return message.pattern ?? ""
        case .partition: return message.partition.map(String.init) ?? ""
        case .offset: return message.offset.map(String.init) ?? ""
        case .key: return message.key ?? ""
        case .payload: return message.payload
        }
    }

    // Tab-separated with a header row, the way a grid copies, so it pastes into a spreadsheet.
    static func tsv(_ entries: [LiveMessageEntry], kind: PluginLiveMessageKind) -> String {
        let columns = columns(for: kind)
        let header = columns.map(\.title).joined(separator: "\t")
        let rows = entries.map { entry in
            columns.map { column in
                value(of: column, in: entry)
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }
            .joined(separator: "\t")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static func csv(_ entries: [LiveMessageEntry], kind: PluginLiveMessageKind) -> String {
        let columns = columns(for: kind)
        let lines = [columns.map { quoted($0.title) }.joined(separator: ",")] + entries.map { entry in
            columns.map { quoted(value(of: $0, in: entry)) }.joined(separator: ",")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
