//
//  RoutineDisplayLabel.swift
//  TablePro
//

import Foundation

/// A routine row shows its bare name, unless the name repeats inside its own section. Then every
/// row that shares that name shows its argument list too, because two PostgreSQL overloads drawn
/// as two identical rows give the reader no way to tell which one they are about to open.
enum RoutineDisplayLabel {
    static func labels(for routines: [RoutineInfo]) -> [RoutineInfo.ID: String] {
        var countsByName: [String: Int] = [:]
        for routine in routines {
            countsByName[routine.name, default: 0] += 1
        }
        var labels: [RoutineInfo.ID: String] = [:]
        for routine in routines {
            labels[routine.id] = label(for: routine, isAmbiguous: countsByName[routine.name, default: 0] > 1)
        }
        return labels
    }

    static func label(for routine: RoutineInfo, isAmbiguous: Bool) -> String {
        guard isAmbiguous,
              let signature = routine.argumentSignature,
              !signature.isEmpty else {
            return routine.name
        }
        return "\(routine.name)\(signature)"
    }

    /// What Copy with Signature writes. Always qualified, always parenthesised when the engine
    /// gave a parameter list, because the pasteboard has no section to disambiguate it.
    static func copyableSignature(for routine: RoutineInfo) -> String {
        guard let signature = routine.argumentSignature, !signature.isEmpty else {
            return routine.qualifiedName
        }
        return "\(routine.qualifiedName)\(signature)"
    }
}
