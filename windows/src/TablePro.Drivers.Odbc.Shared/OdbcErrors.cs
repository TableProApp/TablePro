using System.Data.Common;
using System.Data.Odbc;
using System.Text;

namespace TablePro.Drivers.Odbc;

/// <summary>Which ODBC driver an engine loads, and what to tell the user when Windows does not have it.</summary>
internal sealed record OdbcDriverInfo(string EngineName, string DefaultDriver, string InstallHint);

/// <summary>
/// A server or driver error with the driver manager's decoration removed. It stays a <see cref="DbException"/>, so
/// code that tells database failures from bugs still does.
/// </summary>
internal sealed class OdbcDriverException : DbException
{
    private readonly string? _sqlState;

    public OdbcDriverException()
    {
    }

    public OdbcDriverException(string message)
        : base(message)
    {
    }

    public OdbcDriverException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public OdbcDriverException(string message, string? sqlState, int nativeError, Exception innerException)
        : base(message, innerException)
    {
        _sqlState = sqlState;
        NativeError = nativeError;
    }

    public override string? SqlState => _sqlState;

    public int NativeError { get; }
}

internal static class OdbcErrors
{
    /// <summary>The driver manager found no driver of that name.</summary>
    public const string DriverNotFound = "IM002";

    /// <summary>The driver is registered but its DLL would not load, most often a 32-bit driver in a 64-bit app.</summary>
    public const string DriverNotLoaded = "IM003";

    /// <summary>
    /// Removes what the driver manager and the driver put in front of the server's text:
    /// <c>ERROR [42S02] [SAP AG][LIBODBCHDB DLL][HDBODBC] Base table or view not found;259 invalid table name</c>
    /// becomes <c>invalid table name (error 259)</c>. Each line is one ODBC diagnostic record.
    /// </summary>
    public static string Clean(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return message;
        }

        var lines = new List<string>();
        foreach (var raw in message.Split('\n'))
        {
            var line = CleanLine(raw.Trim());
            if (line.Length > 0 && !lines.Contains(line, StringComparer.Ordinal))
            {
                lines.Add(line);
            }
        }

        return lines.Count == 0 ? message.Trim() : string.Join('\n', lines);
    }

    public static Exception Translate(OdbcException exception)
    {
        var first = exception.Errors.Count > 0 ? exception.Errors[0] : null;
        return new OdbcDriverException(Clean(exception.Message), first?.SQLState, first?.NativeError ?? 0, exception);
    }

    /// <summary>A failed connect, with a missing or unloadable driver named plainly instead of as IM002.</summary>
    public static Exception ForConnect(OdbcException exception, OdbcDriverInfo info, string driverName)
    {
        if (HasState(exception, DriverNotFound))
        {
            return new InvalidOperationException(
                $"The {info.EngineName} ODBC driver \"{driverName}\" is not installed. {info.InstallHint}",
                exception);
        }

        if (HasState(exception, DriverNotLoaded))
        {
            return new InvalidOperationException(
                $"Windows found the {info.EngineName} ODBC driver \"{driverName}\" but could not load it. TablePro is a 64-bit app and needs the 64-bit driver. {info.InstallHint}",
                exception);
        }

        return Translate(exception);
    }

    public static bool HasState(OdbcException exception, string sqlState)
    {
        foreach (OdbcError error in exception.Errors)
        {
            if (string.Equals(error.SQLState, sqlState, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string CleanLine(string line)
    {
        var text = line.AsSpan();
        if (text.StartsWith("ERROR [", StringComparison.OrdinalIgnoreCase))
        {
            var close = text.IndexOf(']');
            text = close < 0 ? text : text[(close + 1)..].TrimStart();
        }

        // Vendor, DLL and driver tags, as many as the stack added.
        while (text.Length > 0 && text[0] == '[')
        {
            var close = text.IndexOf(']');
            if (close < 0)
            {
                break;
            }

            text = text[(close + 1)..].TrimStart();
        }

        // HANA's ODBC driver writes the SQLSTATE's generic text, then ";<code> <server message>".
        var semicolon = text.IndexOf(';');
        if (semicolon >= 0)
        {
            var rest = text[(semicolon + 1)..];
            var digits = 0;
            while (digits < rest.Length && char.IsAsciiDigit(rest[digits]))
            {
                digits++;
            }

            if (digits > 0 && digits < rest.Length && rest[digits] == ' ')
            {
                return new StringBuilder().Append(rest[(digits + 1)..].Trim()).Append(" (error ").Append(rest[..digits]).Append(')').ToString();
            }
        }

        return text.Trim().ToString();
    }
}
