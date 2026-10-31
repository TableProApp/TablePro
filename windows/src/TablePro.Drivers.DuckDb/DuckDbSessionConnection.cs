using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using DuckDB.NET.Data;

namespace TablePro.Drivers.DuckDb;

/// <summary>
/// The shared browse, count and save code names parameters the way they appear in the SQL text (<c>$p0</c>), while
/// DuckDB.NET binds a parameter by its bare name and reports <c>$p0</c> as never provided. These subclasses accept
/// either spelling, so every command the session creates binds.
/// </summary>
internal sealed class DuckDbSessionConnection(string connectionString) : DuckDBConnection(connectionString)
{
    protected override DbCommand CreateDbCommand() => new SessionCommand { Connection = this };

    private sealed class SessionCommand : DuckDBCommand
    {
        protected override DbParameter CreateDbParameter() => new SessionParameter();
    }

    private sealed class SessionParameter : DuckDBParameter
    {
        [AllowNull]
        public override string ParameterName
        {
            get => base.ParameterName;
            set => base.ParameterName = value is { Length: > 1 } && value[0] == '$' ? value[1..] : value;
        }
    }
}
