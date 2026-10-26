import Foundation

/// Each routine's parameter list, put together from one read of `information_schema.PARAMETERS`.
///
/// The list used to come from a `GROUP_CONCAT` subquery per routine. MySQL 5.x and MariaDB fill
/// `PARAMETERS` from every routine on the server and refill it for each row of a correlated subquery:
/// with 300 routines in the database and 3,000 on the server it took 11.1 s on 5.6.51 and 6.5 s on
/// MariaDB 10.6.28, against 0.1 s for the two reads apart, and a larger server ran past the read
/// timeout with 2013. `GROUP_CONCAT` also stops at `group_concat_max_len`, 1024 bytes on MySQL,
/// which cut a long list mid-word.
public struct MySQLRoutineSignatures: Sendable {
    private struct Routine: Hashable {
        let schema: String
        let type: String
        let name: String
    }

    private var parameters: [Routine: [String]] = [:]

    public init() {}

    /// One row of `MySQLObjectQueries.routineParameters`, taken in the order the read returns them.
    /// The parts are joined the way `CONCAT_WS` joins them: a missing one, such as a function
    /// parameter's mode, leaves no gap.
    public mutating func append(
        schema: String,
        type: String,
        routine: String,
        mode: String?,
        name: String?,
        dataType: String?
    ) {
        let parameter = [mode, name, dataType].compactMap { $0 }.joined(separator: " ")
        parameters[Routine(schema: schema, type: type.uppercased(), name: routine), default: []].append(parameter)
    }

    /// `(IN a int, OUT b date)`, or `()` for a routine the read listed no parameter for.
    public func signature(schema: String, type: String, routine: String) -> String {
        let listed = parameters[Routine(schema: schema, type: type.uppercased(), name: routine)] ?? []
        return "(\(listed.joined(separator: ", ")))"
    }
}
