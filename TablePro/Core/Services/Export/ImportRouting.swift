//
//  ImportRouting.swift
//  TablePro
//

import Foundation

struct ImportFormatOption: Identifiable, Equatable {
    let id: String
    let name: String

    var submenuLabel: String {
        String(format: String(localized: "From %@\u{2026}"), name)
    }

    var standaloneLabel: String {
        String(format: String(localized: "Import %@\u{2026}"), name)
    }
}

enum ImportSheetRoute: Equatable {
    case statement(formatId: String)
    case rowMapping(formatId: String)
}

enum ImportRouting {
    static func route(formatId: String, requiresTargetTable: Bool) -> ImportSheetRoute {
        requiresTargetTable ? .rowMapping(formatId: formatId) : .statement(formatId: formatId)
    }
}
