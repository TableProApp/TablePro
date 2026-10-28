using System.Numerics;
using TablePro.Core.Results;

namespace TablePro.Core.Copy;

/// <summary>
/// Turns a value one provider read into one another provider can bind for the target column. Within one type family
/// values pass through untouched; across families a value keeps its CLR type where the target takes it and is
/// otherwise written as the text the grid shows, which every engine parses for its own types.
/// </summary>
public static class CopyValueAdapter
{
    public static object? Adapt(object? value, SqlTypeShape target, TypeFamily targetFamily, bool sharesTypes)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (value is null or DBNull)
        {
            return null;
        }

        if (sharesTypes)
        {
            return value;
        }

        return value switch
        {
            string or bool or byte[] or decimal or double or float or long or int or short or byte or DateTime or DateOnly => value,
            sbyte or ushort or uint => Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture),
            // Each arm is boxed itself: a conditional of long and decimal would widen both to decimal.
            ulong big => big <= long.MaxValue ? (object)(long)big : (decimal)big,
            BigInteger huge => huge >= (BigInteger)decimal.MinValue && huge <= (BigInteger)decimal.MaxValue ? (decimal)huge : huge.ToString(System.Globalization.CultureInfo.InvariantCulture),

            // Only engines with a UUID type take a Guid; SQLite would store one as a BLOB.
            Guid guid => target.Category == SqlTypeCategory.Uuid && targetFamily is TypeFamily.PostgreSql or TypeFamily.SqlServer or TypeFamily.DuckDb
                ? guid
                : guid.ToString("D"),
            DateTimeOffset moment => target.HasTimeZone && targetFamily is TypeFamily.PostgreSql or TypeFamily.SqlServer or TypeFamily.Oracle or TypeFamily.DuckDb
                ? moment
                : (object)moment.UtcDateTime,
            TimeOnly time => targetFamily == TypeFamily.Sqlite ? time.ToString("HH:mm:ss.FFFFFFF", System.Globalization.CultureInfo.InvariantCulture) : time.ToTimeSpan(),
            TimeSpan span => span,
            _ => CellFormatter.Format(value),
        };
    }
}
