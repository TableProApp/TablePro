//
//  CoreLogBridge.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The core's log lines in the Mac's unified log. The line's message is the event's callsite, fixed when the core was
// built; it and the fields named in `publicNames` go public. Every other field goes private, the event's own text among
// them, since a driver can put what a server sent in it.
nonisolated final class CoreLogBridge: CoreLogSink, @unchecked Sendable {
    // The core's fixed list. A field the core sends as public under another name goes private, so a later core
    // that widens the list cannot widen the Mac's log by itself.
    static let publicNames: Set<String> = ["code", "kind", "reason", "count"]

    struct Rendered: Equatable {
        let level: OSLogType
        let category: String
        let publicText: String
        let privateText: String
    }

    private static let sync = Logger(subsystem: "com.TablePro", category: "SyncEngineHost")
    private static let core = Logger(subsystem: "com.TablePro", category: "Core")

    // Once at launch, before the core opens a store: a line logged earlier goes nowhere.
    static func install() {
        setCoreLogSink(sink: CoreLogBridge(), level: .info)
    }

    func log(line: CoreLogLine) {
        let rendered = Self.render(line)
        let logger = rendered.category == "SyncEngineHost" ? Self.sync : Self.core
        if rendered.privateText.isEmpty {
            logger.log(level: rendered.level, "\(rendered.publicText, privacy: .public)")
        } else {
            logger.log(
                level: rendered.level,
                "\(rendered.publicText, privacy: .public) \(rendered.privateText, privacy: .private)"
            )
        }
    }

    static func render(_ line: CoreLogLine) -> Rendered {
        let shown = line.publicFields.filter { publicNames.contains($0.name) }
        let kept = line.publicFields.filter { !publicNames.contains($0.name) } + line.privateFields
        return Rendered(
            level: level(line.level),
            category: line.target.hasPrefix("tablepro_sync") ? "SyncEngineHost" : "Core",
            publicText: ([line.message] + shown.map(pair)).joined(separator: " "),
            privateText: kept.map(pair).joined(separator: " ")
        )
    }

    private static func pair(_ field: CoreLogField) -> String {
        "\(field.name)=\(field.value)"
    }

    // The unified log has no warning level; a warning is a notice, kept on disk as errors are.
    private static func level(_ level: CoreLogLevel) -> OSLogType {
        switch level {
        case .error: .error
        case .warn: .default
        case .info: .info
        case .debug, .trace: .debug
        }
    }
}
