using System.Globalization;

namespace TablePro.Core.Editing;

/// <summary>
/// Turns what the user typed into a value of the column's provider type, so strict engines such as PostgreSQL bind
/// an integer to an integer column instead of refusing text.
/// </summary>
public static class ValueParser
{
    public static bool TryParse(string? text, Type clrType, out object? value)
    {
        if (text is null)
        {
            value = null;
            return true;
        }

        var inv = CultureInfo.InvariantCulture;
        var type = Nullable.GetUnderlyingType(clrType) ?? clrType;
        var ok = true;
        value = type switch
        {
            _ when type == typeof(string) => text,
            _ when type == typeof(int) => int.TryParse(text, NumberStyles.Integer, inv, out var i) ? i : Fail(ref ok),
            _ when type == typeof(long) => long.TryParse(text, NumberStyles.Integer, inv, out var l) ? l : Fail(ref ok),
            _ when type == typeof(short) => short.TryParse(text, NumberStyles.Integer, inv, out var s) ? s : Fail(ref ok),
            _ when type == typeof(byte) => byte.TryParse(text, NumberStyles.Integer, inv, out var b) ? b : Fail(ref ok),
            _ when type == typeof(sbyte) => sbyte.TryParse(text, NumberStyles.Integer, inv, out var sb) ? sb : Fail(ref ok),
            _ when type == typeof(ushort) => ushort.TryParse(text, NumberStyles.Integer, inv, out var us) ? us : Fail(ref ok),
            _ when type == typeof(uint) => uint.TryParse(text, NumberStyles.Integer, inv, out var ui) ? ui : Fail(ref ok),
            _ when type == typeof(ulong) => ulong.TryParse(text, NumberStyles.Integer, inv, out var ul) ? ul : Fail(ref ok),
            // No thousands separators: "1,5" typed with a decimal comma must fail rather than save 15.
            _ when type == typeof(decimal) => decimal.TryParse(text, NumberStyles.Float, inv, out var m) ? m : Fail(ref ok),
            _ when type == typeof(double) => double.TryParse(text, NumberStyles.Float, inv, out var d) ? d : Fail(ref ok),
            _ when type == typeof(float) => float.TryParse(text, NumberStyles.Float, inv, out var f) ? f : Fail(ref ok),
            _ when type == typeof(bool) => ParseBool(text) ?? Fail(ref ok),
            _ when type == typeof(Guid) => Guid.TryParse(text, out var g) ? g : Fail(ref ok),
            _ when type == typeof(DateTime) => DateTime.TryParse(text, inv, DateTimeStyles.AllowWhiteSpaces, out var dt) ? dt : Fail(ref ok),
            _ when type == typeof(DateTimeOffset) => DateTimeOffset.TryParse(text, inv, DateTimeStyles.AllowWhiteSpaces, out var dto) ? dto : Fail(ref ok),
            _ when type == typeof(DateOnly) => DateOnly.TryParse(text, inv, out var date) ? date : Fail(ref ok),
            _ when type == typeof(TimeOnly) => TimeOnly.TryParse(text, inv, out var time) ? time : Fail(ref ok),
            _ when type == typeof(TimeSpan) => TimeSpan.TryParse(text, inv, out var ts) ? ts : Fail(ref ok),
            _ when type == typeof(byte[]) => ParseHex(text) ?? Fail(ref ok),
            _ => text,
        };

        return ok;
    }

    private static object? Fail(ref bool ok)
    {
        ok = false;
        return null;
    }

    private static object? ParseBool(string text) => text.Trim().ToUpperInvariant() switch
    {
        "1" or "TRUE" or "T" or "YES" or "Y" => true,
        "0" or "FALSE" or "F" or "NO" or "N" => false,
        _ => null,
    };

    private static byte[]? ParseHex(string text)
    {
        var span = text.AsSpan().Trim();
        if (span.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            span = span[2..];
        }

        try
        {
            return Convert.FromHexString(span);
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
