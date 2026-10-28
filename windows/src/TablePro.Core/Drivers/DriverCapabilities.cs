using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Core.Drivers;

// Optional features a session implements when its engine has them. The app asks with a type test
// (`session is IServerActivityProvider activity`) and hides what an engine cannot do.

/// <summary>Turns structure edits into the engine's DDL, for the review sheet before anything runs.</summary>
public interface ISchemaDdlProvider
{
    /// <summary>The statements for one change, in the order they must run. Empty when the engine cannot express it.</summary>
    IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change);

    /// <summary>The column types the structure editor offers, most common first.</summary>
    IReadOnlyList<string> CommonDataTypes { get; }
}

/// <summary>The server dashboard: who is connected and what they run.</summary>
public interface IServerActivityProvider
{
    Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken);

    /// <summary>The column of <see cref="GetActivityAsync"/> that identifies a session for <see cref="TerminateAsync"/>.</summary>
    string ProcessIdColumn { get; }

    Task TerminateAsync(object processId, CancellationToken cancellationToken);
}

/// <summary>Logins, users and roles, read-only.</summary>
public interface IUserListProvider
{
    Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken);
}

/// <summary>Creating and dropping whole databases from the database switcher.</summary>
public interface IDatabaseAdministration
{
    string BuildCreateDatabase(string name);

    string BuildDropDatabase(string name);
}

/// <summary>Server variables and status counters, shown on the server dashboard.</summary>
public interface IServerVariablesProvider
{
    Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken);
}
