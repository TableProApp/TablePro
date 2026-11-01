using System.Globalization;

namespace TablePro.Core.Generation;

/// <summary>
/// Values spelled the way every engine reads them, without the current culture or time zone, so the same seed gives the
/// same text on every machine: <c>2024-03-01</c>, <c>2024-03-01 13:05:00</c>, <c>12.50</c>.
/// </summary>
public static class RowValueText
{
    public static string? Invariant(object? value) => value switch
    {
        null => null,
        string s => s,
        bool b => b ? "true" : "false",
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        DateTime dt => dt.ToString(dt.TimeOfDay == TimeSpan.Zero ? "yyyy-MM-dd" : dt.Ticks % TimeSpan.TicksPerSecond == 0 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        DateTimeOffset dto => dto.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFFzzz", CultureInfo.InvariantCulture),
        TimeOnly t => t.ToString(t.Ticks % TimeSpan.TicksPerSecond == 0 ? "HH:mm:ss" : "HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        TimeSpan ts => ts.ToString("c", CultureInfo.InvariantCulture),
        Guid g => g.ToString("D"),
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        byte[] bytes => Convert.ToHexString(bytes),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString(),
    };

    /// <summary>A count of steps of 10^-scale as an exact decimal that keeps its places: 1250 at scale 2 is 12.50.</summary>
    public static decimal Decimal(long steps, int scale)
    {
        var magnitude = steps < 0 ? (ulong)(-(steps + 1)) + 1 : (ulong)steps;
        return new decimal((int)(uint)magnitude, (int)(uint)(magnitude >> 32), 0, steps < 0, (byte)Math.Clamp(scale, 0, 28));
    }
}

/// <summary>
/// Two independent 64-bit hashes of a value's invariant text. Remembering a million unique values as strings would
/// hold every string; two hashes collide too rarely to matter for test data.
/// </summary>
public readonly record struct RowFingerprint(ulong First, ulong Second)
{
    public static RowFingerprint Of(object? value) => Of([value]);

    public static RowFingerprint Of(ReadOnlySpan<object?> values)
    {
        var first = 0xCBF2_9CE4_8422_2325UL;
        var second = 0x6A09_E667_F3BC_C909UL;
        foreach (var value in values)
        {
            switch (value)
            {
                case null:
                    Feed(0);
                    break;
                case byte[] bytes:
                    Feed(2);
                    foreach (var b in bytes)
                    {
                        Feed(b);
                    }

                    break;
                default:
                    Feed(1);
                    foreach (var c in RowValueText.Invariant(value)!)
                    {
                        Feed((byte)c);
                        Feed((byte)(c >> 8));
                    }

                    break;
            }

            Feed(0xFF);
        }

        return new RowFingerprint(first, second);

        void Feed(byte b)
        {
            first = (first ^ b) * 0x0000_0100_0000_01B3;
            second = (second ^ b) * 0x9E37_79B9_7F4A_7C15;
            second = (second << 29) | (second >> 35);
        }
    }
}
