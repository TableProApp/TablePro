//
//  CoreErrorLogShape.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProLogRedaction

// A core error's code is a constant the core names it by (core AGENTS.md, Errors carry a code), so the public log
// carries it; the message and what a server said stay private.
extension CoreError: @retroactive PubliclyLoggableError {
    public var publicLogDescription: String {
        switch self {
        case .Cancelled:
            "CoreError.Cancelled"
        case .Failed(let info):
            "CoreError.Failed(\(info.code))"
        }
    }
}
