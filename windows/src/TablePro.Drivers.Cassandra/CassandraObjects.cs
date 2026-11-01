using TablePro.Core.Schema;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// How keyspace objects without a kind of their own are listed. <see cref="ObjectKind"/> has no user-defined type or
/// aggregate, so both are listed as functions and told apart by their comment, which the sidebar also shows.
/// </summary>
public static class CassandraObjects
{
    public const string UserTypeComment = "user-defined type";
    public const string AggregateComment = "aggregate";

    public static DatabaseObject UserType(string keyspace, string name, IReadOnlyList<string> fieldNames, IReadOnlyList<string> fieldTypes)
    {
        var fields = string.Join(", ", fieldNames.Select((field, i) => $"{field} {(i < fieldTypes.Count ? fieldTypes[i] : "?")}"));
        return new DatabaseObject(new ObjectName(keyspace, name), ObjectKind.Function, Comment: $"{UserTypeComment} ({fields})");
    }

    public static DatabaseObject Aggregate(string keyspace, string name) =>
        new(new ObjectName(keyspace, name), ObjectKind.Function, Comment: AggregateComment);

    public static bool IsUserType(DatabaseObject obj) => obj.Comment?.StartsWith(UserTypeComment, StringComparison.Ordinal) == true;

    public static bool IsAggregate(DatabaseObject obj) => obj.Comment == AggregateComment;

    /// <summary>Keyspaces the server keeps for itself, which the sidebar leaves out.</summary>
    public static bool IsSystemKeyspace(string keyspace) =>
        keyspace == "system" || keyspace.StartsWith("system_", StringComparison.Ordinal) || keyspace.StartsWith("dse_", StringComparison.Ordinal);
}
