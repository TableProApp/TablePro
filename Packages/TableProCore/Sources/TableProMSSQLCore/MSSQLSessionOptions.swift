import Foundation

/// The session state a SQL Server connection has to be put into before anything else runs.
///
/// FreeTDS db-lib inherits Sybase's 1990s defaults and hands back a session with every one of
/// these off. Measured on SQL Server 2022 by reading `SESSIONPROPERTY` for all seven straight
/// after `dbopen`: `0 0 0 0 0 0 0`. Every other client reaches the server with the six ON options
/// already on, because ODBC, OLE DB, JDBC and .NET all set them in the login packet, and
/// `sqlcmd -I` does the same; db-lib is the outlier.
///
/// Six on and `NUMERIC_ROUNDABORT` off is the SET profile SQL Server requires for an indexed view,
/// an index on a computed column, a filtered index, an XML data type method and a spatial index
/// operation. Miss any one and the server answers `Msg 1934`, naming the options rather than the
/// real problem. Two of them reached users. The stored procedure and function lists were empty on
/// every connection, because the catalog query aggregates a parameter list through `FOR XML PATH`
/// and `.value()`. And no INSERT, UPDATE or DELETE could touch a table carrying a filtered index or
/// an index on a computed column, so such a row edit could never be saved. Both were measured
/// failing and then succeeding on one connection, either side of this establishment.
///
/// `NUMERIC_ROUNDABORT` already arrives off, so setting it changes nothing on a default server. It
/// is set anyway because a database or a login can carry it on, and a session that inherits it
/// fails those same writes while all six ON options read correctly. Measured: with the six on and
/// `NUMERIC_ROUNDABORT` on, the INSERT fails with `Msg 1934` naming `NUMERIC_ROUNDABORT` alone.
///
/// `ANSI_NULLS` and `CONCAT_NULL_YIELDS_NULL` also decide how the user's own SQL reads: `col = NULL`
/// stops matching, and concatenating a NULL yields NULL. That is the standard behaviour, the
/// behaviour every other client gets, and the behaviour Microsoft documents these options as always
/// having in a future version. A session that keeps db-lib's defaults is the surprising one.
///
/// Statements are sent one at a time rather than as a batch, so a server that refuses one still
/// receives the rest.
public enum MSSQLSessionOptions {
    /// Required on. `ARITHABORT` is implied by `ANSI_WARNINGS` at database compatibility level 90
    /// and above, which is every server TDS 7.4 can reach, so it is belt and braces rather than
    /// load-bearing; it is set because Microsoft documents it as part of the required profile.
    public static let optionsRequiredOn = [
        "ANSI_NULLS",
        "ANSI_PADDING",
        "ANSI_WARNINGS",
        "ARITHABORT",
        "CONCAT_NULL_YIELDS_NULL",
        "QUOTED_IDENTIFIER"
    ]

    /// Required off. The one member of the profile that is not an "ON".
    public static let optionsRequiredOff = ["NUMERIC_ROUNDABORT"]

    /// Every option in the profile, paired with the value the server requires.
    public static var requiredValues: [(name: String, isOn: Bool)] {
        optionsRequiredOn.map { ($0, true) } + optionsRequiredOff.map { ($0, false) }
    }

    /// `TEXTSIZE` defaults to 4096 bytes on db-lib, which truncates a large text or image column
    /// mid-value and reads as corrupted data rather than as a limit.
    public static let maxTextSize = "SET TEXTSIZE \(Int32.max)"

    public static let ansiDefaults = requiredValues
        .map { "SET \($0.name) \($0.isOn ? "ON" : "OFF")" }
        .joined(separator: " ")

    /// Run in this order: the profile first, because a server that drops the connection while
    /// applying `TEXTSIZE` should not leave the session in db-lib's defaults.
    public static let establishment = [ansiDefaults, maxTextSize]
}
