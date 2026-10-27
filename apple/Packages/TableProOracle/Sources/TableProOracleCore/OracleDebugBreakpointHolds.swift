import Foundation

// The lines a caller removes each breakpoint by, keyed by the line it landed on. One sent at start is held by the line
// it asked for, since its caller never learns where it landed; one set later, by the line `setBreakpoint` answered.
struct OracleDebugBreakpointHolds {
    private var holders: [OracleDebugUnit: [Int: Set<Int>]] = [:]

    mutating func hold(_ landed: Int, in unit: OracleDebugUnit, by line: Int) {
        holders[unit, default: [:]][landed, default: []].insert(line)
    }

    // A pending JDWP breakpoint lands again once its unit loads, possibly on a later line.
    mutating func move(_ landed: Int, to line: Int, in unit: OracleDebugUnit) {
        guard line != landed, let held = holders[unit]?.removeValue(forKey: landed) else { return }
        holders[unit, default: [:]][line, default: []].formUnion(held)
    }

    mutating func drop(_ landed: Int, in unit: OracleDebugUnit) {
        holders[unit]?[landed] = nil
    }

    // The landed line of the breakpoint `line` names, once no other line holds it; nil while one still does.
    mutating func release(_ line: Int, in unit: OracleDebugUnit) -> Int? {
        guard let landed = holders[unit]?.first(where: { $0.value.contains(line) })?.key else {
            drop(line, in: unit)
            return line
        }
        holders[unit]?[landed]?.remove(line)
        guard holders[unit]?[landed]?.isEmpty == true else { return nil }
        drop(landed, in: unit)
        return landed
    }
}
