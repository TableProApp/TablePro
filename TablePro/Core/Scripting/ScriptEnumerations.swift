//
//  ScriptEnumerations.swift
//  TablePro
//

import Foundation

/// The four-character codes `TablePro.sdef` gives each enumerator.
///
/// Cocoa carries an sdef enumeration as a `FourCharCode`, so a scriptable property backed by one is
/// typed `FourCharCode` and these are the values it may hold. Every switch is exhaustive on purpose:
/// a case added to `SafeModeLevel` or `TabType` has to be given a code and an sdef enumerator in the
/// same change, and the compiler is what says so. `DatabaseType` gets no enumeration at all, because
/// it is an open string a plugin can extend and an sdef enumeration cannot be.
internal enum ScriptEnumerations {
    internal static func code(for level: SafeModeLevel) -> FourCharCode {
        switch level {
        case .silent: fourCharCode("TPm1")
        case .alert: fourCharCode("TPm2")
        case .alertFull: fourCharCode("TPm3")
        case .safeMode: fourCharCode("TPm4")
        case .safeModeFull: fourCharCode("TPm5")
        case .readOnly: fourCharCode("TPm6")
        }
    }

    internal static func code(for access: ExternalAccessLevel) -> FourCharCode {
        switch access {
        case .blocked: fourCharCode("TPa1")
        case .readOnly: fourCharCode("TPm6")
        case .readWrite: fourCharCode("TPa3")
        }
    }

    internal static func code(for tabType: TabType) -> FourCharCode {
        switch tabType {
        case .query: fourCharCode("TPk1")
        case .table: fourCharCode("TPk2")
        case .createTable: fourCharCode("TPk3")
        case .erDiagram: fourCharCode("TPk4")
        case .serverDashboard: fourCharCode("TPk5")
        case .usersRoles: fourCharCode("TPk6")
        case .insights: fourCharCode("TPk7")
        case .objectSource: fourCharCode("TPk8")
        }
    }

    internal static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            code = (code << 8) | FourCharCode(byte)
        }
        return code
    }
}
