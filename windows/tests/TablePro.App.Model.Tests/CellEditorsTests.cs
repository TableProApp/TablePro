using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class CellEditorsTests
{
    private static readonly string[] Sizes = ["small", "medium", "large"];

    private static readonly DateOnly Picked = new(2025, 1, 2);

    [Fact]
    public void EachKindOpensItsOwnEditorAndEverythingElseTheTextBox()
    {
        Assert.Equal(CellEditor.Toggle, CellEditors.For(Column(ValueKind.Bool)));
        Assert.Equal(CellEditor.Choice, CellEditors.For(Column(ValueKind.Text, Sizes)));
        Assert.Equal(CellEditor.Choices, CellEditors.For(Column(ValueKind.Text, Sizes, multiple: true)));
        Assert.Equal(CellEditor.Date, CellEditors.For(Column(ValueKind.Date)));
        Assert.Equal(CellEditor.Time, CellEditors.For(Column(ValueKind.Time)));
        Assert.Equal(CellEditor.Time, CellEditors.For(Column(ValueKind.TimeWithOffset)));
        Assert.Equal(CellEditor.Timestamp, CellEditors.For(Column(ValueKind.Timestamp)));
        Assert.Equal(CellEditor.Timestamp, CellEditors.For(Column(ValueKind.TimestampWithOffset)));
        Assert.Equal(CellEditor.Text, CellEditors.For(Column(ValueKind.Text)));
        Assert.Equal(CellEditor.Text, CellEditors.For(Column(ValueKind.Json)));
        Assert.Equal(CellEditor.Text, CellEditors.For(Column(ValueKind.Integer)));
    }

    [Fact]
    public void ALongLabelListAndASetWithAnEmptyLabelAreTyped()
    {
        var count = CellEditors.MaximumLabels + 1;
        string[] many = [.. Enumerable.Range(0, count).Select(i => "v" + i.ToString(CultureInfo.InvariantCulture))];

        Assert.Equal(CellEditor.Choice, CellEditors.For(Column(ValueKind.Text, many[..CellEditors.MaximumLabels])));
        Assert.Equal(CellEditor.Text, CellEditors.For(Column(ValueKind.Text, many)));
        Assert.Equal(CellEditor.Text, CellEditors.For(Column(ValueKind.Text, ["", "a"], multiple: true)));
        Assert.Equal(CellEditor.Choice, CellEditors.For(Column(ValueKind.Text, ["", "a"])));
    }

    [Theory]
    [InlineData("", "true")]
    [InlineData("1", "0")]
    [InlineData("0", "1")]
    [InlineData("00", "1")]
    [InlineData("2", "0")]
    [InlineData("-1", "0")]
    [InlineData("+0", "1")]
    [InlineData("true", "false")]
    [InlineData("TRUE", "false")]
    [InlineData(" t ", "false")]
    [InlineData("Yes", "false")]
    [InlineData("on", "false")]
    [InlineData("f", "true")]
    [InlineData("no", "true")]
    [InlineData("OFF", "true")]
    [InlineData("maybe", "true")]
    public void ABooleanTogglesInTheSpellingItWasStoredIn(string stored, string toggled) =>
        Assert.Equal(toggled, CellEditors.Toggled(stored));

    [Theory]
    [InlineData("y", true)]
    [InlineData("N", false)]
    [InlineData("12345678901234567890", true)]
    [InlineData("-0", false)]
    [InlineData("", null)]
    [InlineData("-", null)]
    [InlineData("1.0", null)]
    public void ABooleanReadsAsTheCoreReadsIt(string text, bool? value) =>
        Assert.Equal(value, CellEditors.ReadBool(text));

    [Fact]
    public void ASetTogglesOneLabelAndWritesTheTypesOrder()
    {
        Assert.True(CellEditors.Members("large,small", Sizes).SetEquals(["small", "large"]));
        Assert.Equal("small,medium,large", CellEditors.ToggledMember("large,small", Sizes, "medium"));
        Assert.Equal("medium", CellEditors.ToggledMember("small,medium", Sizes, "small"));
        Assert.Equal("large", CellEditors.ToggledMember(string.Empty, Sizes, "large"));
        Assert.Equal(string.Empty, CellEditors.ToggledMember("large", Sizes, "large"));
        Assert.Equal("small,medium", CellEditors.ToggledMember("small, huge", Sizes, "medium"));
        Assert.Throws<ArgumentException>(() => CellEditors.ToggledMember("small", Sizes, "huge"));
    }

    [Theory]
    [InlineData("2024-03-15", 2024, 3, 15)]
    [InlineData("2024-03-15 10:30:00", 2024, 3, 15)]
    [InlineData("2024-02-29T08:00:00Z", 2024, 2, 29)]
    [InlineData("0001-01-01", 1, 1, 1)]
    public void ADateIsReadFromTheStartOfTheValue(string text, int year, int month, int day) =>
        Assert.Equal(new DateOnly(year, month, day), CellEditors.DateOf(text));

    [Theory]
    [InlineData("")]
    [InlineData("infinity")]
    [InlineData("2023-02-29")]
    [InlineData("0000-01-01")]
    [InlineData("10000-01-01")]
    [InlineData("0044-03-15 BC")]
    [InlineData("2024-3-15")]
    [InlineData("2024-03-150")]
    [InlineData("10:30:00")]
    public void TextWithNoDateAPickerShowsReadsAsNone(string text) => Assert.Null(CellEditors.DateOf(text));

    [Theory]
    [InlineData("10:30", 10, 30, 0)]
    [InlineData("10:30:45.123456", 10, 30, 45)]
    [InlineData("23:59:59+07:00", 23, 59, 59)]
    [InlineData("2024-03-15 08:05:00", 8, 5, 0)]
    [InlineData("2024-03-15T08:05:09Z", 8, 5, 9)]
    public void ATimeIsReadAloneOrAfterTheDate(string text, int hour, int minute, int second) =>
        Assert.Equal(new TimeOnly(hour, minute, second), CellEditors.TimeOf(text));

    [Theory]
    [InlineData("")]
    [InlineData("100:00:00")]
    [InlineData("-01:00:00")]
    [InlineData("24:00:00")]
    [InlineData("10:60")]
    [InlineData("1:30")]
    [InlineData("2024-03-15")]
    [InlineData("2024-03-15x10:00")]
    public void TextWithNoTimeOfDayReadsAsNone(string text) => Assert.Null(CellEditors.TimeOf(text));

    [Theory]
    [InlineData("2024-03-15", "2025-01-02")]
    [InlineData("2024-03-15 10:30:00", "2025-01-02 10:30:00")]
    [InlineData("2024-03-15T10:30:00.5+07:00", "2025-01-02T10:30:00.5+07:00")]
    [InlineData("", "2025-01-02")]
    [InlineData("infinity", "2025-01-02")]
    [InlineData("0044-03-15 BC", "2025-01-02")]
    public void APickedDateReplacesTheDateAndKeepsTheRest(string text, string written) =>
        Assert.Equal(written, CellEditors.WithDate(text, Picked));

    [Theory]
    [InlineData("10:30:45.123456", "08:05:45.123456")]
    [InlineData("10:30:00+07:00", "08:05:00+07:00")]
    [InlineData("10:30", "08:05")]
    [InlineData("2024-03-15 10:30:00Z", "2024-03-15 08:05:00Z")]
    [InlineData("", "08:05:00")]
    [InlineData("100:00:00", "08:05:00")]
    public void APickedTimeReplacesTheHourAndMinuteAndKeepsTheRest(string text, string written) =>
        Assert.Equal(written, CellEditors.WithTime(text, 8, 5));

    [Theory]
    [InlineData("2024-03-15 10:30:45.5+07:00", "2025-01-02 08:05:45.5+07:00")]
    [InlineData("2024-03-15T10:30:00Z", "2025-01-02T08:05:00Z")]
    [InlineData("2024-03-15 10:30", "2025-01-02 08:05")]
    [InlineData("2024-03-15", "2025-01-02 08:05:00")]
    [InlineData("10:30:00", "2025-01-02 08:05:00")]
    [InlineData("", "2025-01-02 08:05:00")]
    [InlineData("-infinity", "2025-01-02 08:05:00")]
    public void APickedDateAndTimeReplaceBothOrWriteANewValue(string text, string written) =>
        Assert.Equal(written, CellEditors.WithDateAndTime(text, Picked, 8, 5));

    [Fact]
    public void ATimePastTheDayIsRefused() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => CellEditors.WithTime("10:30", 24, 0));

    private static EditColumn Column(ValueKind kind, IReadOnlyList<string>? labels = null, bool multiple = false) =>
        new("c", true, true, CellEdit.Null.Instance, true, false, true, false, kind, labels, multiple);

    [Fact]
    public void ANewValueInAColumnWithAnOffsetCarriesTheOneGiven()
    {
        Assert.Equal("08:05:00+07:00", CellEditors.WithTime(string.Empty, 8, 5, TimeSpan.FromHours(7)));
        Assert.Equal(
            "2024-03-15 08:05:00-03:30",
            CellEditors.WithDateAndTime(string.Empty, new DateOnly(2024, 3, 15), 8, 5, new TimeSpan(-3, -30, 0)));
        Assert.Equal(
            "2024-03-15 08:05:00+01",
            CellEditors.WithDateAndTime("2023-01-02 10:30:00+01", new DateOnly(2024, 3, 15), 8, 5, TimeSpan.FromHours(7)));
    }
}
