using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model;

// What a cell opens with on Enter, F2 or a double-click; Tab and Edit as text open the TextBox.
public enum CellEditor
{
    Text,
    Toggle,
    Choice,
    Choices,
    Date,
    Time,
    Timestamp,
}

// The text each editor writes, in the spellings the core reads back as it reads typed text.
public static class CellEditors
{
    // A longer list is easier to type than to scroll through in a menu.
    public const int MaximumLabels = 100;

    private const int DateLength = 10;
    private const int HourMinuteLength = 5;

    private static readonly string[] TrueWords = ["true", "t", "yes", "y", "on", "1"];
    private static readonly string[] FalseWords = ["false", "f", "no", "n", "off", "0"];

    public static CellEditor For(EditColumn column)
    {
        ArgumentNullException.ThrowIfNull(column);
        var listed = column.Labels.Count is >= 1 and <= MaximumLabels;
        return column.Kind switch
        {
            ValueKind.Bool => CellEditor.Toggle,
            _ when listed && !column.Multiple => CellEditor.Choice,
            // An empty label in a set has no text of its own between the commas.
            _ when listed && !column.Labels.Contains(string.Empty) => CellEditor.Choices,
            ValueKind.Date => CellEditor.Date,
            ValueKind.Time or ValueKind.TimeWithOffset => CellEditor.Time,
            ValueKind.Timestamp or ValueKind.TimestampWithOffset => CellEditor.Timestamp,
            _ => CellEditor.Text,
        };
    }

    // As the core reads a boolean: its words, and an integer as true unless zero. Null for NULL and other text.
    public static bool? ReadBool(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.Trim();
        if (TrueWords.Contains(trimmed, StringComparer.OrdinalIgnoreCase))
        {
            return true;
        }

        if (FalseWords.Contains(trimmed, StringComparer.OrdinalIgnoreCase))
        {
            return false;
        }

        return IntegerIsZero(trimmed) is { } zero ? !zero : null;
    }

    // NULL and false become true. A value stored as a number stays one, so an integer column gets 1 or 0.
    public static string Toggled(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var next = ReadBool(text) != true;
        return IntegerIsZero(text.Trim()) is null ? (next ? "true" : "false") : (next ? "1" : "0");
    }

    // The labels a set's value names between its commas; text that names no label is left out.
    public static IReadOnlySet<string> Members(string text, IReadOnlyList<string> labels)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(labels);
        var named = new HashSet<string>(StringComparer.Ordinal);
        foreach (var part in text.Split(','))
        {
            named.Add(part);
            named.Add(part.Trim());
        }

        return labels.Where(named.Contains).ToHashSet(StringComparer.Ordinal);
    }

    // The label added or taken out, the rest kept, in the type's order as the server writes a set.
    public static string ToggledMember(string text, IReadOnlyList<string> labels, string label)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(labels);
        ArgumentNullException.ThrowIfNull(label);
        if (!labels.Contains(label))
        {
            throw new ArgumentException("The label is not one of the set's.", nameof(label));
        }

        var members = Members(text, labels).ToHashSet(StringComparer.Ordinal);

        if (!members.Remove(label))
        {
            members.Add(label);
        }

        return string.Join(',', labels.Where(members.Contains));
    }

    public static DateOnly? DateOf(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Parse(text).Date;
    }

    public static TimeOnly? TimeOf(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Parse(text).Time;
    }

    // The date replaced and the rest kept; text with no date to replace becomes the date alone.
    public static string WithDate(string text, DateOnly date)
    {
        ArgumentNullException.ThrowIfNull(text);
        var stamp = Parse(text);
        return stamp.Date is null ? DateText(date) : string.Concat(DateText(date), text.AsSpan(DateLength));
    }

    // The hour and minute replaced, the rest kept; text with no time becomes HH:mm:00 and the offset a column needs.
    public static string WithTime(string text, int hour, int minute, TimeSpan? offset = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        var stamp = Parse(text);
        var clock = Clock(hour, minute);
        return stamp.Time is null
            ? clock + ":00" + OffsetText(offset)
            : string.Concat(text.AsSpan(0, stamp.TimeAt), clock, text.AsSpan(stamp.TimeAt + HourMinuteLength));
    }

    // Both replaced in a value that has both, the separator and the rest kept; anything else gets a new value.
    public static string WithDateAndTime(string text, DateOnly date, int hour, int minute, TimeSpan? offset = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        var stamp = Parse(text);
        var clock = Clock(hour, minute);
        if (stamp.Date is null || stamp.Time is null)
        {
            return $"{DateText(date)} {clock}:00{OffsetText(offset)}";
        }

        return string.Concat(
            DateText(date),
            text.AsSpan(DateLength, stamp.TimeAt - DateLength),
            clock,
            text.AsSpan(stamp.TimeAt + HourMinuteLength));
    }

    // Null when the text is not an integer, as the core reads one: a sign, then digits.
    private static bool? IntegerIsZero(string text)
    {
        var digits = text.AsSpan();
        if (digits.Length > 0 && digits[0] is '+' or '-')
        {
            digits = digits[1..];
        }

        return digits.Length > 0 && !digits.ContainsAnyExceptInRange('0', '9') ? !digits.ContainsAnyExcept('0') : null;
    }

    private static string DateText(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string OffsetText(TimeSpan? offset) => offset is not { } value
        ? string.Empty
        : string.Create(
            CultureInfo.InvariantCulture,
            $"{(value < TimeSpan.Zero ? '-' : '+')}{Math.Abs(value.Hours):00}:{Math.Abs(value.Minutes):00}");

    private static string Clock(int hour, int minute)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(hour);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(hour, 23);
        ArgumentOutOfRangeException.ThrowIfNegative(minute);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(minute, 59);
        return string.Create(CultureInfo.InvariantCulture, $"{hour:00}:{minute:00}");
    }

    // A year before AD 1 or past 9999, or a duration such as 100:00:00, has no part a picker shows.
    private static Stamp Parse(string text)
    {
        var span = text.AsSpan();
        if (span.EndsWith(" BC", StringComparison.OrdinalIgnoreCase))
        {
            return default;
        }

        if (ReadDate(span) is { } date)
        {
            if (span.Length == DateLength)
            {
                return new Stamp(date, null, 0);
            }

            if (span[DateLength] is not (' ' or 'T'))
            {
                return default;
            }

            var timeAt = DateLength + 1;
            return ReadTime(span, timeAt) is { } dated ? new Stamp(date, dated, timeAt) : new Stamp(date, null, 0);
        }

        return ReadTime(span, 0) is { } time ? new Stamp(null, time, 0) : default;
    }

    private static DateOnly? ReadDate(ReadOnlySpan<char> text)
    {
        if (text.Length < DateLength
            || text[4] != '-'
            || text[7] != '-'
            || !Digits(text, 0, 4, out var year)
            || !Digits(text, 5, 2, out var month)
            || !Digits(text, 8, 2, out var day)
            || year < 1
            || month is < 1 or > 12
            || day < 1
            || day > DateTime.DaysInMonth(year, month))
        {
            return null;
        }

        return new DateOnly(year, month, day);
    }

    private static TimeOnly? ReadTime(ReadOnlySpan<char> text, int at)
    {
        if (text.Length < at + HourMinuteLength
            || text[at + 2] != ':'
            || !Digits(text, at, 2, out var hour)
            || !Digits(text, at + 3, 2, out var minute)
            || hour > 23
            || minute > 59)
        {
            return null;
        }

        var end = at + HourMinuteLength;
        var second = 0;
        if (text.Length >= end + 3 && text[end] == ':' && Digits(text, end + 1, 2, out var seconds) && seconds <= 59)
        {
            second = seconds;
            end += 3;
            if (text.Length > end + 1 && text[end] == '.' && char.IsAsciiDigit(text[end + 1]))
            {
                end += 2;
                while (end < text.Length && char.IsAsciiDigit(text[end]))
                {
                    end++;
                }
            }
        }

        // A digit straight after means more digits than a time of day has.
        return end < text.Length && char.IsAsciiDigit(text[end]) ? null : new TimeOnly(hour, minute, second);
    }

    private static bool Digits(ReadOnlySpan<char> text, int start, int count, out int value)
    {
        value = 0;
        foreach (var character in text.Slice(start, count))
        {
            if (!char.IsAsciiDigit(character))
            {
                return false;
            }

            value = (value * 10) + (character - '0');
        }

        return true;
    }

    // TimeAt is where the hour starts, read only when Time is set.
    private readonly record struct Stamp(DateOnly? Date, TimeOnly? Time, int TimeAt);
}
