using System.Globalization;
using System.Numerics;

namespace TablePro.Core.Compare;

/// <summary>
/// How two cells are ordered as keys and judged equal as values, across engines that hand the same value over as
/// different CLR types: SQLite gives a <see cref="long"/> where PostgreSQL gives an <see cref="int"/>, and a SQLite
/// timestamp arrives as text.
/// </summary>
/// <remarks>
/// The merge join walks both sides in the order the servers sorted them, so <see cref="CompareKeys"/> has to agree
/// with that order. Numbers compare as exact integers or decimals, never through <see cref="double"/>, because two
/// 64-bit ids one apart are the same double and the walk would match the wrong rows. Text compares in UTF-8 byte
/// order, which is what binary collations sort by. Any other collation is caught by the order check in
/// <see cref="DataDiffEngine"/> rather than guessed at.
/// </remarks>
public static class CompareValues
{
    private const long TicksPerSecond = TimeSpan.TicksPerSecond;

    /// <summary>Orders two non-null key components.</summary>
    public static int CompareKeys(object? left, object? right, bool ignoreCase)
    {
        if (left is null || right is null)
        {
            return left is null ? (right is null ? 0 : -1) : 1;
        }

        // Two strings are text to the server too, so "10" sorts before "9" and no parse may reorder them.
        if (left is string leftString && right is string rightString)
        {
            return CompareUtf8(leftString, rightString, ignoreCase);
        }

        if (Number.TryFrom(left, out var leftNumber) && Number.TryFrom(right, out var rightNumber))
        {
            return leftNumber.CompareTo(rightNumber);
        }

        if (TryNumericPair(left, right, out leftNumber, out rightNumber))
        {
            return leftNumber.CompareTo(rightNumber);
        }

        if (TryTicks(left, out var leftTicks) && TryTicks(right, out var rightTicks))
        {
            return leftTicks.CompareTo(rightTicks);
        }

        if (left is byte[] leftBytes && right is byte[] rightBytes)
        {
            return leftBytes.AsSpan().SequenceCompareTo(rightBytes);
        }

        return CompareUtf8(Text(left), Text(right), ignoreCase);
    }

    /// <summary>Whether two cells hold the same value under the comparison's tolerances.</summary>
    public static bool AreEqual(object? left, object? right, DataCompareOptions options)
    {
        left = left is DBNull ? null : left;
        right = right is DBNull ? null : right;
        if (left is null || right is null)
        {
            return left is null && right is null;
        }

        if (left is string leftText && right is string rightText)
        {
            return string.Equals(leftText, rightText, StringComparison.Ordinal) || TemporalTextEqual(leftText, rightText, options);
        }

        if (left is byte[] leftBytes && right is byte[] rightBytes)
        {
            return leftBytes.AsSpan().SequenceEqual(rightBytes);
        }

        if ((Number.TryFrom(left, out var leftNumber) && Number.TryFrom(right, out var rightNumber))
            || TryNumericPair(left, right, out leftNumber, out rightNumber))
        {
            if (options.FloatTolerance > 0 && (leftNumber.IsReal || rightNumber.IsReal))
            {
                return Math.Abs(leftNumber.ToDouble() - rightNumber.ToDouble()) <= options.FloatTolerance;
            }

            return leftNumber.CompareTo(rightNumber) == 0;
        }

        if (TryTicks(left, out var leftTicks) && TryTicks(right, out var rightTicks))
        {
            var unit = TickUnit(options.TimestampFractionalDigits);
            return FloorDivide(leftTicks, unit) == FloorDivide(rightTicks, unit);
        }

        return string.Equals(Text(left), Text(right), StringComparison.Ordinal);
    }

    /// <summary>A key component as a person reads it.</summary>
    public static string Describe(object? value) => value switch
    {
        null or DBNull => "NULL",
        byte[] bytes => "0x" + Convert.ToHexString(bytes.AsSpan(0, Math.Min(bytes.Length, 32))) + (bytes.Length > 32 ? "…" : string.Empty),
        _ => Text(value),
    };

    /// <summary>
    /// Orders two strings by their UTF-8 bytes without encoding them. UTF-16 code units already sort in code point
    /// order except that surrogates (U+D800 to U+DFFF) sit below U+E000 to U+FFFF, so those two ranges swap.
    /// </summary>
    public static int CompareUtf8(ReadOnlySpan<char> left, ReadOnlySpan<char> right, bool ignoreCase)
    {
        var length = Math.Min(left.Length, right.Length);
        for (var i = 0; i < length; i++)
        {
            var a = left[i];
            var b = right[i];
            if (ignoreCase)
            {
                a = char.ToLowerInvariant(a);
                b = char.ToLowerInvariant(b);
            }

            if (a != b)
            {
                return CodePointRank(a) - CodePointRank(b);
            }
        }

        return left.Length.CompareTo(right.Length);
    }

    internal static string Text(object value) => value switch
    {
        string s => s,
        Guid g => g.ToString("D"),
        bool b => b ? "true" : "false",
        DateTime dt => dt.ToString("O", CultureInfo.InvariantCulture),
        DateTimeOffset dto => dto.ToString("O", CultureInfo.InvariantCulture),
        byte[] bytes => Convert.ToBase64String(bytes),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };

    private static int CodePointRank(char c) => c >= 0xE000 ? c - 0x800 : c >= 0xD800 ? c + 0x2000 : c;

    // A number against numeric text: SQLite keeps whatever was inserted, so one side's 42 can be the other's "42".
    private static bool TryNumericPair(object left, object right, out Number leftNumber, out Number rightNumber)
    {
        leftNumber = default;
        rightNumber = default;
        return (left is string) != (right is string)
            &&(Number.TryFrom(left, out leftNumber) || Number.TryParse(left as string, out leftNumber))
            && (Number.TryFrom(right, out rightNumber) || Number.TryParse(right as string, out rightNumber));
    }

    private static bool TemporalTextEqual(string left, string right, DataCompareOptions options)
    {
        // Only text that looks like a date is tried, so ordinary strings never pay for a parse.
        if (left.Length < 10 || right.Length < 10 || !char.IsAsciiDigit(left[0]) || !char.IsAsciiDigit(right[0]))
        {
            return false;
        }

        if (!TryParseInstant(left, out var leftTicks) || !TryParseInstant(right, out var rightTicks))
        {
            return false;
        }

        var unit = TickUnit(options.TimestampFractionalDigits);
        return FloorDivide(leftTicks, unit) == FloorDivide(rightTicks, unit);
    }

    private static bool TryTicks(object value, out long ticks)
    {
        switch (value)
        {
            case DateTime dt:
                ticks = (dt.Kind == DateTimeKind.Local ? dt.ToUniversalTime() : dt).Ticks;
                return true;
            case DateTimeOffset dto:
                ticks = dto.UtcTicks;
                return true;
            case DateOnly d:
                ticks = d.ToDateTime(TimeOnly.MinValue).Ticks;
                return true;
            case TimeOnly t:
                ticks = t.Ticks;
                return true;
            case TimeSpan ts:
                ticks = ts.Ticks;
                return true;
            case string s when s.Length >= 8:
                return TryParseInstant(s, out ticks);
            default:
                ticks = 0;
                return false;
        }
    }

    private static bool TryParseInstant(string text, out long ticks)
    {
        if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AllowWhiteSpaces, out var parsed))
        {
            ticks = parsed.UtcTicks;
            return true;
        }

        if (TimeSpan.TryParse(text, CultureInfo.InvariantCulture, out var span))
        {
            ticks = span.Ticks;
            return true;
        }

        ticks = 0;
        return false;
    }

    // A tick is 100 ns, so seven fractional digits is the finest a CLR timestamp holds.
    private static long TickUnit(int fractionalDigits)
    {
        var unit = TicksPerSecond;
        for (var i = 0; i < Math.Clamp(fractionalDigits, 0, 7); i++)
        {
            unit /= 10;
        }

        return unit;
    }

    private static long FloorDivide(long value, long divisor)
    {
        var quotient = value / divisor;
        return value % divisor < 0 ? quotient - 1 : quotient;
    }

    /// <summary>A number held exactly where it can be: an integer, a decimal, or failing both a double.</summary>
    private readonly struct Number : IComparable<Number>
    {
        private readonly Int128 _integer;
        private readonly decimal _decimal;
        private readonly double _real;
        private readonly byte _kind;

        private Number(Int128 integer)
        {
            _integer = integer;
            _kind = 0;
        }

        private Number(decimal value)
        {
            _decimal = value;
            _kind = 1;
        }

        private Number(double value)
        {
            _real = value;
            _kind = 2;
        }

        public bool IsReal => _kind == 2;

        public static bool TryFrom(object value, out Number number)
        {
            switch (value)
            {
                case int v: number = new((Int128)v); return true;
                case long v: number = new((Int128)v); return true;
                case short v: number = new((Int128)v); return true;
                case byte v: number = new((Int128)v); return true;
                case sbyte v: number = new((Int128)v); return true;
                case ushort v: number = new((Int128)v); return true;
                case uint v: number = new((Int128)v); return true;
                case ulong v: number = new((Int128)v); return true;
                case Int128 v: number = new(v); return true;
                case bool v: number = new(v ? Int128.One : Int128.Zero); return true;
                case decimal v: number = new(v); return true;
                case double v: number = new(v); return true;
                case float v: number = new((double)v); return true;
                case BigInteger v when v >= (BigInteger)Int128.MinValue && v <= (BigInteger)Int128.MaxValue:
                    number = new((Int128)v);
                    return true;
                default:
                    number = default;
                    return false;
            }
        }

        public static bool TryParse(string? text, out Number number)
        {
            number = default;
            if (string.IsNullOrWhiteSpace(text))
            {
                return false;
            }

            var span = text.AsSpan().Trim();
            if (Int128.TryParse(span, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer))
            {
                number = new(integer);
                return true;
            }

            if (decimal.TryParse(span, NumberStyles.Float, CultureInfo.InvariantCulture, out var exact))
            {
                number = new(exact);
                return true;
            }

            return false;
        }

        public double ToDouble() => _kind switch
        {
            0 => (double)_integer,
            1 => (double)_decimal,
            _ => _real,
        };

        public int CompareTo(Number other)
        {
            if (_kind == 0 && other._kind == 0)
            {
                return _integer.CompareTo(other._integer);
            }

            if (_kind != 2 && other._kind != 2 && TryDecimal(out var left) && other.TryDecimal(out var right))
            {
                return left.CompareTo(right);
            }

            if (IsReal && other.IsReal)
            {
                return _real.CompareTo(other._real);
            }

            // A double against an exact value compares in decimal when the double fits, so a large integer is not
            // rounded to the nearest double and matched with its neighbour.
            var real = IsReal ? _real : other._real;
            var exact = IsReal ? other : this;
            if (!double.IsFinite(real) || Math.Abs(real) >= 7.9e28 || !exact.TryDecimal(out var exactValue))
            {
                return ToDouble().CompareTo(other.ToDouble());
            }

            var widened = (decimal)real;
            return IsReal ? widened.CompareTo(exactValue) : exactValue.CompareTo(widened);
        }

        private bool TryDecimal(out decimal value)
        {
            switch (_kind)
            {
                case 1:
                    value = _decimal;
                    return true;
                case 0 when _integer >= (Int128)decimal.MinValue && _integer <= (Int128)decimal.MaxValue:
                    value = (decimal)_integer;
                    return true;
                default:
                    value = 0;
                    return false;
            }
        }
    }
}
