import Foundation

// The driver builds this grid from a SLOWLOG GET reply and the Server Dashboard reads it back by column name.
public enum RedisSlowLogGrid {
    public static let id = "ID"
    public static let time = "Time"
    public static let durationMicroseconds = "Duration (µs)"
    public static let command = "Command"
    public static let client = "Client"
    public static let clientName = "Client Name"

    public static let columns = [id, time, durationMicroseconds, command, client, clientName]
    public static let columnTypeNames = ["Int64", "Int64", "Int64", "String", "String", "String"]
}
