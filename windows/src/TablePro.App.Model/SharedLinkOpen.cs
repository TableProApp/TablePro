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

// Links come from other launches at any time: one opens at a time, in order, and a link already waiting is kept once.
public sealed class PendingSharedLinks
{
    private readonly Queue<string> _waiting = new();
    private string? _opening;

    // True when nothing is opening, so the caller starts taking links; otherwise the one opening takes it in turn.
    public bool Offer(string link)
    {
        ArgumentNullException.ThrowIfNull(link);
        if (link == _opening || _waiting.Contains(link))
        {
            return false;
        }

        _waiting.Enqueue(link);
        return _opening is null;
    }

    // The next link to open, null once none waits.
    public string? TakeNext()
    {
        _opening = _waiting.TryDequeue(out var next) ? next : null;
        return _opening;
    }
}
