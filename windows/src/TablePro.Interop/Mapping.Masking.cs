using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static MaskStyle Style(Native.MaskStyleTag style) => style switch
    {
        Native.MaskStyleTag.LastFour => MaskStyle.LastFour,
        Native.MaskStyleTag.Email => MaskStyle.Email,
        Native.MaskStyleTag.Hash => MaskStyle.Hash,
        Native.MaskStyleTag.Null => MaskStyle.Null,
        _ => MaskStyle.Full,
    };

    public static Native.MaskStyleTag Style(MaskStyle style) => style switch
    {
        MaskStyle.LastFour => Native.MaskStyleTag.LastFour,
        MaskStyle.Email => Native.MaskStyleTag.Email,
        MaskStyle.Hash => Native.MaskStyleTag.Hash,
        MaskStyle.Null => Native.MaskStyleTag.Null,
        _ => Native.MaskStyleTag.Full,
    };

    public static Native.ShareColumnChoice Choice(ShareColumnChoice choice) => choice switch
    {
        ShareColumnChoice.Mask mask => new Native.ShareColumnChoice.Mask(Style(mask.Style)),
        ShareColumnChoice.Remove => new Native.ShareColumnChoice.Remove(),
        _ => new Native.ShareColumnChoice.Keep(),
    };

    public static SensitiveKind Kind(Native.SensitiveKindTag kind) => kind switch
    {
        Native.SensitiveKindTag.Card => SensitiveKind.Card,
        Native.SensitiveKindTag.Iban => SensitiveKind.Iban,
        Native.SensitiveKindTag.Jwt => SensitiveKind.Jwt,
        Native.SensitiveKindTag.ApiKey => SensitiveKind.ApiKey,
        Native.SensitiveKindTag.Email => SensitiveKind.Email,
        Native.SensitiveKindTag.Phone => SensitiveKind.Phone,
        Native.SensitiveKindTag.Ip => SensitiveKind.Ip,
        _ => throw new InvalidOperationException($"The core sent a kind this build does not know: {kind}"),
    };

    public static ShareColumnMasking ColumnMasking(Native.ShareColumnMasking column) => new(
        column.Name,
        column.Suggestion is { } suggestion
            ? new MaskSuggestion(
                Style(suggestion.Style),
                suggestion.Reason switch
                {
                    Native.MaskReason.Values values => new MaskReason.Values(Kind(values.Kind)),
                    Native.MaskReason.ColumnName name => new MaskReason.ColumnName(name.Term),
                    _ => throw new InvalidOperationException("The core sent a reason this build does not know."),
                })
            : null);

    public static ShareSummary Summary(Native.ShareSummary summary) => new(
        Count(summary.RowsSent),
        checked((int)summary.ColumnsSent),
        summary.ColumnsTruncated,
        summary.Refused switch
        {
            Native.ShareRefusal.Cell cell => new ShareRefusal.Cell(cell.Column),
            Native.ShareRefusal.FirstRow => ShareRefusal.FirstRow.Instance,
            Native.ShareRefusal.NoColumns => ShareRefusal.NoColumns.Instance,
            _ => null,
        });

    public static PersonalDataHit Hit(Native.PersonalDataHitInfo hit) => new(Kind(hit.Kind), checked((int)hit.Line));
}
