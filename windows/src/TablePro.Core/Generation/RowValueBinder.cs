using System.Globalization;
using TablePro.Core.Editing;

namespace TablePro.Core.Generation;

/// <summary>
/// Converts a generated value to the type the provider reads the column as, so a strict engine such as PostgreSQL
/// binds a <c>date</c> to a date column rather than refusing text. A value that does not convert is left as it was,
/// for the server's own conversion and error to decide.
/// </summary>
public static class RowValueBinder
{
    public static object? ToProviderType(object? value, Type? clrType)
    {
        if (value is null || clrType is null || clrType == typeof(object))
        {
            return value;
        }

        var target = Nullable.GetUnderlyingType(clrType) ?? clrType;
        if (target.IsInstanceOfType(value))
        {
            return value;
        }

        switch (value)
        {
            case bool flag when IsNumber(target):
                return Convert.ChangeType(flag ? 1 : 0, target, CultureInfo.InvariantCulture);
            case DateOnly date when target == typeof(DateTime):
                return date.ToDateTime(TimeOnly.MinValue);
            case DateOnly date when target == typeof(DateTimeOffset):
                return new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);
            case DateTime moment when target == typeof(DateOnly):
                return DateOnly.FromDateTime(moment);
            case DateTime moment when target == typeof(DateTimeOffset):
                return new DateTimeOffset(DateTime.SpecifyKind(moment, DateTimeKind.Unspecified), TimeSpan.Zero);
            case TimeOnly time when target == typeof(TimeSpan):
                return time.ToTimeSpan();
            case Guid guid when target == typeof(byte[]):
                return guid.ToByteArray();
            case IConvertible when IsNumber(value.GetType()) && IsNumber(target):
                try
                {
                    return Convert.ChangeType(value, target, CultureInfo.InvariantCulture);
                }
                catch (OverflowException)
                {
                    return value;
                }
        }

        var text = RowValueText.Invariant(value);
        if (target == typeof(string))
        {
            return text;
        }

        return ValueParser.TryParse(text, target, out var parsed) ? parsed : value;
    }

    private static bool IsNumber(Type type) =>
        type == typeof(int) || type == typeof(long) || type == typeof(short) || type == typeof(byte) || type == typeof(sbyte)
        || type == typeof(ushort) || type == typeof(uint) || type == typeof(ulong) || type == typeof(decimal) || type == typeof(double)
        || type == typeof(float);
}
