using TablePro.Interop;

namespace TablePro.App.Model;

public enum SharedLinkStep
{
    AskPassword,

    // The password typed was wrong; the prompt asks again and says so.
    AskPasswordAgain,
    Unavailable,

    // The owner hid the SQL, so there is nothing to open.
    HiddenSql,
    Open,
    Failed,
}

// tablepro://share?token=<token> opens the link's SQL in a new query tab, never runs it and carries no connection.
public static class SharedLinkOpen
{
    public const string Scheme = "tablepro";

    // A launch through the execution alias passes the link as an argument rather than a protocol activation.
    public static string? LinkIn(IEnumerable<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        return arguments
            .Select(argument => argument.Trim().Trim('"'))
            .FirstOrDefault(argument => argument.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase));
    }

    public static SharedLinkStep After(PublicShare shared)
    {
        ArgumentNullException.ThrowIfNull(shared);
        return string.IsNullOrWhiteSpace(shared.Sql) ? SharedLinkStep.HiddenSql : SharedLinkStep.Open;
    }

    public static SharedLinkStep After(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        return error.Code switch
        {
            "account.share_password_required" => SharedLinkStep.AskPassword,
            "account.share_password_wrong" => SharedLinkStep.AskPasswordAgain,
            "account.not_found" => SharedLinkStep.Unavailable,
            _ => SharedLinkStep.Failed,
        };
    }

    // The tab is named after the link, or the general name when its owner gave none.
    public static string TabTitle(PublicShare shared, string fallback)
    {
        ArgumentNullException.ThrowIfNull(shared);
        return string.IsNullOrWhiteSpace(shared.Title) ? fallback : shared.Title.Trim();
    }
}
