//
//  RedisReplyGrid.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProRedisCore

struct RedisReplyGrid: Equatable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [PluginRow]

    func queryResult(startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    static func hash(_ reply: RedisReply) -> RedisReplyGrid {
        RedisReplyGrid(
            columns: ["Field", "Value"],
            columnTypeNames: ["String", "String"],
            rows: pairRows(reply.arrayValue ?? [])
        )
    }

    static func list(_ reply: RedisReply, startOffset: Int) -> RedisReplyGrid {
        let items = reply.arrayValue ?? []
        return RedisReplyGrid(
            columns: ["Index", "Value"],
            columnTypeNames: ["Int64", "String"],
            rows: items.enumerated().map { index, item in
                [.text(String(startOffset + index)), .text(item.displayText)]
            }
        )
    }

    static func set(_ reply: RedisReply) -> RedisReplyGrid {
        RedisReplyGrid(
            columns: ["Member"],
            columnTypeNames: ["String"],
            rows: singleRows(reply.arrayValue ?? [])
        )
    }

    static func sortedSet(_ reply: RedisReply, withScores: Bool) -> RedisReplyGrid {
        let items = reply.arrayValue ?? []
        guard withScores else {
            return RedisReplyGrid(columns: ["Member"], columnTypeNames: ["String"], rows: singleRows(items))
        }
        return RedisReplyGrid(
            columns: ["Member", "Score"],
            columnTypeNames: ["String", "Double"],
            rows: pairRows(items)
        )
    }

    static func stream(_ reply: RedisReply) -> RedisReplyGrid {
        let entries = reply.arrayValue ?? []
        return RedisReplyGrid(
            columns: ["ID", "Fields"],
            columnTypeNames: ["String", "String"],
            rows: entries.compactMap(streamRow)
        )
    }

    static func config(_ reply: RedisReply) -> RedisReplyGrid {
        RedisReplyGrid(
            columns: ["Parameter", "Value"],
            columnTypeNames: ["String", "String"],
            rows: pairRows(reply.arrayValue ?? [])
        )
    }

    static func slowLog(_ reply: RedisReply) -> RedisReplyGrid {
        RedisReplyGrid(
            columns: RedisSlowLogGrid.columns,
            columnTypeNames: RedisSlowLogGrid.columnTypeNames,
            rows: (reply.arrayValue ?? []).compactMap(slowLogRow)
        )
    }

    static func generic(_ reply: RedisReply) -> RedisReplyGrid {
        switch reply {
        case .integer(let value):
            return RedisReplyGrid(columns: ["result"], columnTypeNames: ["Int64"], rows: [[.text(String(value))]])
        case .array(let items):
            return resultColumn(items.map(\.displayText))
        case .error(let message):
            return resultColumn([message])
        default:
            return resultColumn([reply.displayText])
        }
    }

    private static func resultColumn(_ values: [String]) -> RedisReplyGrid {
        RedisReplyGrid(columns: ["result"], columnTypeNames: ["String"], rows: values.map { [.text($0)] })
    }

    private static func singleRows(_ items: [RedisReply]) -> [PluginRow] {
        items.map { [.text($0.displayText)] }
    }

    private static func pairRows(_ items: [RedisReply]) -> [PluginRow] {
        stride(from: 0, to: items.count - 1, by: 2).map { index in
            [.text(items[index].displayText), .text(items[index + 1].displayText)]
        }
    }

    // Redis before 4.0 sends four fields per entry, without the client's address and name.
    private static func slowLogRow(_ entry: RedisReply) -> PluginRow? {
        guard let fields = entry.arrayValue, fields.count >= 4 else { return nil }
        let command = (fields[3].arrayValue ?? []).map(quotedArgument).joined(separator: " ")
        return [
            .text(fields[0].displayText),
            .text(fields[1].displayText),
            .text(fields[2].displayText),
            .text(command),
            fields.count > 4 ? .text(fields[4].displayText) : .null,
            fields.count > 5 ? .text(fields[5].displayText) : .null,
        ]
    }

    private static func quotedArgument(_ argument: RedisReply) -> String {
        if case .data(let bytes) = argument { return RedisArgumentCodec.quote(bytes) }
        return RedisArgumentCodec.quote(argument.displayText)
    }

    private static func streamRow(_ entry: RedisReply) -> PluginRow? {
        guard let parts = entry.arrayValue, parts.count >= 2, let fields = parts[1].arrayValue else {
            return nil
        }
        let fieldPairs = stride(from: 0, to: fields.count - 1, by: 2).map { index in
            "\(fields[index].displayText)=\(fields[index + 1].displayText)"
        }
        return [.text(parts[0].displayText), .text(fieldPairs.joined(separator: ", "))]
    }
}
