//
//  DamengSystemSchemas.swift
//  DamengDriverPlugin
//

import Foundation

/// Two lists, because showing a schema and letting it be dropped are different questions. `listed` is what the
/// sidebar and the pickers treat as system: schemas that hold the engine's own objects. `SYSDBA` is not on it,
/// because it is the administrator login's own default schema and where that login's tables land. The drop guard is
/// wider and matches any spelling: `SYSDBA` also holds a few DM-supplied procedures and `SYSDBO` is the other preset
/// administrator, so a `DROP SCHEMA ... CASCADE` on either is refused even though they list with the user's schemas.
enum DamengSystemSchemas {
    static let listed: [String] = ["SYS", "SYSAUDITOR", "SYSSSO", "CTISYS", "SYSJOB", "SYSGEO2"]

    static let protectedFromDrop: Set<String> = [
        "SYS", "SYSDBA", "SYSDBO", "SYSAUDITOR", "SYSSSO", "CTISYS", "SYSJOB", "SYSGEO2"
    ]

    static func isProtectedFromDrop(_ name: String) -> Bool {
        protectedFromDrop.contains(name.uppercased())
    }
}
