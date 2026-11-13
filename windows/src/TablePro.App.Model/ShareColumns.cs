using TablePro.Interop;

namespace TablePro.App.Model;

public enum ShareColumnAction
{
    Keep,
    Mask,
    Remove,
}

// One shared column: a rule's column starts masked with the rule's style and cannot be kept, a detected one starts
// masked with the suggested style, any other is kept (share-v2 PLAN-MASKING 8.4).
public sealed class ShareColumn
{
    private static readonly MaskStyle[] AllStyles =
        [MaskStyle.Full, MaskStyle.LastFour, MaskStyle.Email, MaskStyle.Hash, MaskStyle.Null];

    internal ShareColumn(ShareColumnMasking masking)
    {
        Name = masking.Name;
        Rule = masking.Rule;
        Untraced = Rule is not null && masking.Untraced;
        Suggestion = Rule is null ? masking.Suggestion : null;
        (Action, Style) = (Rule, Suggestion) switch
        {
            ({ } rule, _) => (ShareColumnAction.Mask, rule),
            (_, { } suggestion) => (ShareColumnAction.Mask, suggestion.Style),
            _ => (ShareColumnAction.Keep, MaskStyle.Full),
        };
        AllowedStyles = Rule is { } ruled ? [.. AllStyles.Where(style => HidesAsMuch(style, ruled))] : AllStyles;
    }

    public string Name { get; }

    // The style the connection's rules mask the column with on every path out.
    public MaskStyle? Rule { get; }

    // Masked because no table column can be named for it, not because a rule names it.
    public bool Untraced { get; }

    public MaskSuggestion? Suggestion { get; }

    public ShareColumnAction Action { get; private set; }

    // The style Mask uses; kept while another action is picked, so a return to Mask finds it.
    public MaskStyle Style { get; private set; }

    public bool AllowsKeep => Rule is null;

    // Under a rule only a style that hides at least as much: the rule's own, Full or NULL.
    public IReadOnlyList<MaskStyle> AllowedStyles { get; }

    public ShareColumnChoice Choice => Action switch
    {
        ShareColumnAction.Remove => ShareColumnChoice.Remove.Instance,
        ShareColumnAction.Mask => new ShareColumnChoice.Mask(Style),
        _ => ShareColumnChoice.Keep.Instance,
    };

    // False for a choice the column refuses, which leaves it as it was.
    public bool Choose(ShareColumnAction action)
    {
        if (action == ShareColumnAction.Keep && !AllowsKeep)
        {
            return false;
        }

        Action = action;
        return true;
    }

    public bool Choose(MaskStyle style)
    {
        if (!AllowedStyles.Contains(style))
        {
            return false;
        }

        Style = style;
        return true;
    }

    // The engine's strictest(rule, style) is the style itself: equal, NULL, or Full over any other.
    private static bool HidesAsMuch(MaskStyle style, MaskStyle rule) =>
        style == rule || style == MaskStyle.Null || (style == MaskStyle.Full && rule != MaskStyle.Null);
}

// The share sheet's Columns list, in the result's order.
public sealed class ShareColumns
{
    private ShareColumns(IReadOnlyList<ShareColumn> columns)
    {
        Columns = columns;
    }

    public static ShareColumns None { get; } = new([]);

    public IReadOnlyList<ShareColumn> Columns { get; }

    public int Masked => Columns.Count(column => column.Action == ShareColumnAction.Mask);

    public int Removed => Columns.Count(column => column.Action == ShareColumnAction.Remove);

    public int Kept => Columns.Count - Removed;

    // "1 column masked, 2 removed." or "3 columns masked, 0 removed."; the removed count shares the noun.
    public string SummaryKey => Masked == 1 ? "ShareColumnsSummaryOne" : "ShareColumnsSummaryMany";

    // The sheet says so under the list, so the user checks the columns before sharing.
    public bool HasDetections => Columns.Any(column => column.Suggestion is not null);

    // A share needs at least one column to send.
    public bool RemovesEveryColumn => Columns.Count > 0 && Removed == Columns.Count;

    public IReadOnlyList<ShareColumnChoice> Choices => [.. Columns.Select(column => column.Choice)];

    public static ShareColumns From(IReadOnlyList<ShareColumnMasking> masking)
    {
        ArgumentNullException.ThrowIfNull(masking);
        return new ShareColumns([.. masking.Select(column => new ShareColumn(column))]);
    }
}

// The resource key that names what a column or a literal looks like ("Looks like: email address"), as macOS words it.
public static class SensitiveWords
{
    private static readonly Dictionary<string, string> NameKinds = new(StringComparer.Ordinal)
    {
        ["email"] = "Email",
        ["mail"] = "Email",
        ["phone"] = "Phone",
        ["mobile"] = "Phone",
        ["tel"] = "Phone",
        ["telephone"] = "Phone",
        ["fax"] = "Phone",
        ["msisdn"] = "Phone",
        ["password"] = "Secret",
        ["passwd"] = "Secret",
        ["pwd"] = "Secret",
        ["secret"] = "Secret",
        ["token"] = "Secret",
        ["apikey"] = "Secret",
        ["accesskey"] = "Secret",
        ["privatekey"] = "Secret",
        ["credential"] = "Secret",
        ["ssn"] = "NationalId",
        ["socialsecurity"] = "NationalId",
        ["nationalid"] = "NationalId",
        ["passport"] = "NationalId",
        ["taxid"] = "NationalId",
        ["tin"] = "NationalId",
        ["creditcard"] = "CardOrAccount",
        ["cardnumber"] = "CardOrAccount",
        ["ccnumber"] = "CardOrAccount",
        ["pan"] = "CardOrAccount",
        ["iban"] = "CardOrAccount",
        ["accountnumber"] = "CardOrAccount",
        ["routingnumber"] = "CardOrAccount",
        ["address"] = "Address",
        ["street"] = "Address",
        ["zip"] = "Address",
        ["zipcode"] = "Address",
        ["postcode"] = "Address",
        ["postal"] = "Address",
        ["dob"] = "BirthDate",
        ["birthdate"] = "BirthDate",
        ["dateofbirth"] = "BirthDate",
        ["birthday"] = "BirthDate",
        ["ip"] = "IpAddress",
        ["ipaddress"] = "IpAddress",
        ["ipv4"] = "IpAddress",
        ["ipv6"] = "IpAddress",
        ["firstname"] = "PersonName",
        ["lastname"] = "PersonName",
        ["fullname"] = "PersonName",
        ["surname"] = "PersonName",
        ["givenname"] = "PersonName",
    };

    // Null for a term the core added after this build; the sheet then shows the term itself.
    public static string? KeyFor(MaskReason reason) => reason switch
    {
        MaskReason.ColumnName name => NameKinds.TryGetValue(name.Term, out var kind) ? "SensitiveName_" + kind : null,
        MaskReason.Values values => KeyFor(values.Kind),
        _ => null,
    };

    public static string KeyFor(SensitiveKind kind) => "SensitiveValue_" + kind;
}
