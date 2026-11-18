using System.Globalization;
using System.Numerics;
using System.Text;

namespace TablePro.DataGrid.Model;

// Mantissa / 10^Scale at any size: a sum of a numeric column must neither drift as double does nor overflow decimal.
public readonly struct ExactDecimal : IComparable<ExactDecimal>, IEquatable<ExactDecimal>
{
    // An exponent past this names a number no column holds, and 10^n of a pasted "1e999999999" would never finish.
    public const int MaxExponent = 400;

    private const string Blanks = " \t\r\n\v\f";
    private const int LongDigits = 18;
    private const int StackDigits = 256;

    private static readonly BigInteger[] Powers = [.. Enumerable.Range(0, 32).Select(n => BigInteger.Pow(10, n))];

    public ExactDecimal(BigInteger mantissa, int scale)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(scale);
        Mantissa = mantissa;
        Scale = scale;
    }

    public BigInteger Mantissa { get; }

    public int Scale { get; }

    public int Sign => Mantissa.Sign;

    public static bool operator ==(ExactDecimal left, ExactDecimal right) => left.Equals(right);

    public static bool operator !=(ExactDecimal left, ExactDecimal right) => !left.Equals(right);

    public static bool operator <(ExactDecimal left, ExactDecimal right) => left.CompareTo(right) < 0;

    public static bool operator <=(ExactDecimal left, ExactDecimal right) => left.CompareTo(right) <= 0;

    public static bool operator >(ExactDecimal left, ExactDecimal right) => left.CompareTo(right) > 0;

    public static bool operator >=(ExactDecimal left, ExactDecimal right) => left.CompareTo(right) >= 0;

    // Invariant and strict: NaN, infinity, group separators and hex are text, not numbers a column should sum.
    public static bool TryParse(ReadOnlySpan<char> text, out ExactDecimal value)
    {
        value = default;
        text = text.Trim(Blanks);
        var index = 0;
        var negative = false;
        if (index < text.Length && text[index] is '+' or '-')
        {
            negative = text[index] == '-';
            index++;
        }
        var start = index;
        var digits = SkipDigits(text, ref index);
        var fraction = 0;
        if (index < text.Length && text[index] == '.')
        {
            index++;
            fraction = SkipDigits(text, ref index);
            digits += fraction;
        }
        if (digits == 0)
        {
            return false;
        }
        var end = index;
        var exponent = 0;
        if (index < text.Length && text[index] is 'e' or 'E')
        {
            index++;
            var negativeExponent = false;
            if (index < text.Length && text[index] is '+' or '-')
            {
                negativeExponent = text[index] == '-';
                index++;
            }
            var exponentStart = index;
            while (index < text.Length && char.IsAsciiDigit(text[index]))
            {
                exponent = (exponent * 10) + (text[index] - '0');
                if (exponent > MaxExponent)
                {
                    return false;
                }
                index++;
            }
            if (index == exponentStart)
            {
                return false;
            }
            exponent = negativeExponent ? -exponent : exponent;
        }
        if (index != text.Length)
        {
            return false;
        }
        var mantissa = ParseDigits(text[start..end], digits);
        if (negative)
        {
            mantissa = -mantissa;
        }
        var scale = fraction - exponent;
        value = scale >= 0 ? new ExactDecimal(mantissa, scale) : new ExactDecimal(mantissa * Power(-scale), 0);
        return true;
    }

    // By value: 1.50 and 1.5 are equal.
    public static int Compare(ExactDecimal left, ExactDecimal right) => left.CompareTo(right);

    public ExactDecimal Add(ExactDecimal other)
    {
        var scale = Math.Max(Scale, other.Scale);
        return new ExactDecimal(ScaledTo(scale) + other.ScaledTo(scale), scale);
    }

    public int CompareTo(ExactDecimal other)
    {
        var scale = Math.Max(Scale, other.Scale);
        return ScaledTo(scale).CompareTo(other.ScaledTo(scale));
    }

    public bool Equals(ExactDecimal other) => CompareTo(other) == 0;

    public override bool Equals(object? obj) => obj is ExactDecimal other && Equals(other);

    public override int GetHashCode()
    {
        var normal = Normalize();
        return HashCode.Combine(normal.Mantissa, normal.Scale);
    }

    // Rounded half away from zero at fractionDigits places.
    public ExactDecimal Divide(long divisor, int fractionDigits)
    {
        ArgumentOutOfRangeException.ThrowIfZero(divisor);
        ArgumentOutOfRangeException.ThrowIfNegative(fractionDigits);
        var numerator = Mantissa;
        BigInteger denominator = divisor;
        if (fractionDigits >= Scale)
        {
            numerator *= Power(fractionDigits - Scale);
        }
        else
        {
            denominator *= Power(Scale - fractionDigits);
        }
        var quotient = BigInteger.DivRem(numerator, denominator, out var remainder);
        if (BigInteger.Abs(remainder) * 2 >= BigInteger.Abs(denominator))
        {
            quotient += numerator.Sign * denominator.Sign;
        }
        return new ExactDecimal(quotient, fractionDigits);
    }

    // Without trailing fractional zeros: 1.500 is 1.5, 0.00 is 0.
    public ExactDecimal Normalize()
    {
        if (Mantissa.IsZero)
        {
            return default;
        }
        var mantissa = Mantissa;
        var scale = Scale;
        while (scale > 0)
        {
            var quotient = BigInteger.DivRem(mantissa, 10, out var remainder);
            if (!remainder.IsZero)
            {
                break;
            }
            mantissa = quotient;
            scale--;
        }
        return new ExactDecimal(mantissa, scale);
    }

    // Every digit, no exponent, with the format's negative sign, decimal separator and, when asked, group separators.
    public string Format(NumberFormatInfo format, bool groupDigits)
    {
        ArgumentNullException.ThrowIfNull(format);
        var digits = BigInteger.Abs(Mantissa).ToString(CultureInfo.InvariantCulture);
        if (digits.Length <= Scale)
        {
            digits = new string('0', Scale - digits.Length + 1) + digits;
        }
        var integral = digits.AsSpan(0, digits.Length - Scale);
        var builder = new StringBuilder(digits.Length + 16);
        if (Mantissa.Sign < 0)
        {
            builder.Append(format.NegativeSign);
        }
        if (groupDigits)
        {
            AppendGrouped(builder, integral, format);
        }
        else
        {
            builder.Append(integral);
        }
        if (Scale > 0)
        {
            builder.Append(format.NumberDecimalSeparator).Append(digits.AsSpan(digits.Length - Scale));
        }
        return builder.ToString();
    }

    public override string ToString() => Format(NumberFormatInfo.InvariantInfo, groupDigits: false);

    private BigInteger ScaledTo(int scale) => scale == Scale ? Mantissa : Mantissa * Power(scale - Scale);

    private static BigInteger Power(int exponent) =>
        exponent < Powers.Length ? Powers[exponent] : BigInteger.Pow(Powers[1], exponent);

    private static int SkipDigits(ReadOnlySpan<char> text, ref int index)
    {
        var start = index;
        while (index < text.Length && char.IsAsciiDigit(text[index]))
        {
            index++;
        }
        return index - start;
    }

    // The digits of text, which holds digits and at most one point.
    private static BigInteger ParseDigits(ReadOnlySpan<char> text, int digits)
    {
        if (digits <= LongDigits)
        {
            var small = 0L;
            foreach (var character in text)
            {
                if (character != '.')
                {
                    small = (small * 10) + (character - '0');
                }
            }
            return small;
        }
        Span<char> buffer = digits <= StackDigits ? stackalloc char[digits] : new char[digits];
        var at = 0;
        foreach (var character in text)
        {
            if (character != '.')
            {
                buffer[at++] = character;
            }
        }
        return BigInteger.Parse(buffer, NumberStyles.None, CultureInfo.InvariantCulture);
    }

    private static void AppendGrouped(StringBuilder builder, ReadOnlySpan<char> integral, NumberFormatInfo format)
    {
        // Separators sit this many digits from the right: each group size in turn, the last repeating, 0 ending them.
        var cuts = new List<int>();
        var sizes = format.NumberGroupSizes;
        var size = 0;
        var at = 0;
        while (sizes.Length > 0)
        {
            var group = sizes[Math.Min(size, sizes.Length - 1)];
            at += group;
            if (group <= 0 || at >= integral.Length)
            {
                break;
            }
            cuts.Add(at);
            size++;
        }
        var next = cuts.Count - 1;
        for (var position = 0; position < integral.Length; position++)
        {
            if (next >= 0 && integral.Length - position == cuts[next])
            {
                builder.Append(format.NumberGroupSeparator);
                next--;
            }
            builder.Append(integral[position]);
        }
    }
}
