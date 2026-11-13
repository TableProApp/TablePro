using TablePro.Interop;

namespace TablePro.App.Model;

public enum ShareColumnAction
{
    Keep,
    Mask,
    Remove,
}

// One shared column: a detected one starts masked with the suggested style and may be kept; any other starts kept
// (share-v2 PLAN-MASKING 8.0 and 8.4).
public sealed class ShareColumn
{
    public static IReadOnlyList<MaskStyle> Styles { get; } =
        [MaskStyle.Full, MaskStyle.LastFour, MaskStyle.Email, MaskStyle.Hash, MaskStyle.Null];

    internal ShareColumn(ShareColumnMasking masking)
    {
        Name = masking.Name;
        Suggestion = masking.Suggestion;
        (Action, Style) = Suggestion is { } suggestion
            ? (ShareColumnAction.Mask, suggestion.Style)
            : (ShareColumnAction.Keep, MaskStyle.Full);
    }

    public string Name { get; }

    public MaskSuggestion? Suggestion { get; }

    public ShareColumnAction Action { get; private set; }

    // The style Mask uses; kept while another action is picked, so a return to Mask finds it.
    public MaskStyle Style { get; private set; }

    public ShareColumnChoice Choice => Action switch
    {
        ShareColumnAction.Remove => ShareColumnChoice.Remove.Instance,
        ShareColumnAction.Mask => new ShareColumnChoice.Mask(Style),
        _ => ShareColumnChoice.Keep.Instance,
    };

    public void Choose(ShareColumnAction action) => Action = action;

    public void Choose(MaskStyle style) => Style = style;
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
