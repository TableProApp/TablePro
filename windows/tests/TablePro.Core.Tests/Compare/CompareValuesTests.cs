using TablePro.Core.Compare;

namespace TablePro.Core.Tests.Compare;

public sealed class CompareValuesTests
{
    [Fact]
    public void IntegersOfDifferentClrTypesCompareByValue()
    {
        Assert.Equal(0, CompareValues.CompareKeys(42, 42L, ignoreCase: false));
        Assert.True(CompareValues.CompareKeys((short)3, 10L, ignoreCase: false) < 0);
        Assert.True(CompareValues.AreEqual(7, 7L, DataCompareOptions.Default));
    }

    [Fact]
    public void LargeIntegersOneApartAreNotEqual()
    {
        // Both round to the same double, which is what made the macOS engine match the wrong rows before the fix.
        const long a = 9_007_199_254_740_993;
        const long b = 9_007_199_254_740_992;

        Assert.True(CompareValues.CompareKeys(a, b, ignoreCase: false) > 0);
        Assert.False(CompareValues.AreEqual(a, b, DataCompareOptions.Default));
    }

    [Fact]
    public void DecimalScaleDoesNotMatter()
    {
        Assert.True(CompareValues.AreEqual(1.50m, 1.5m, DataCompareOptions.Default));
        Assert.True(CompareValues.AreEqual(2, 2.0m, DataCompareOptions.Default));
    }

    [Fact]
    public void FloatToleranceAppliesOnlyWhenSet()
    {
        Assert.False(CompareValues.AreEqual(1.0, 1.0001, DataCompareOptions.Default));
        Assert.True(CompareValues.AreEqual(1.0, 1.0001, DataCompareOptions.Default with { FloatTolerance = 0.001 }));
    }

    [Fact]
    public void NullEqualsOnlyNull()
    {
        Assert.True(CompareValues.AreEqual(null, null, DataCompareOptions.Default));
        Assert.True(CompareValues.AreEqual(DBNull.Value, null, DataCompareOptions.Default));
        Assert.False(CompareValues.AreEqual(null, string.Empty, DataCompareOptions.Default));
        Assert.False(CompareValues.AreEqual(0, null, DataCompareOptions.Default));
    }

    [Fact]
    public void NumericTextMatchesANumberFromAnotherEngine()
    {
        Assert.True(CompareValues.AreEqual("42", 42L, DataCompareOptions.Default));
        Assert.Equal(0, CompareValues.CompareKeys(42, "42", ignoreCase: false));
    }

    [Fact]
    public void TwoStringsSortAsTextEvenWhenTheyLookNumeric()
    {
        Assert.True(CompareValues.CompareKeys("10", "9", ignoreCase: false) < 0);
    }

    [Fact]
    public void TextSortsByUtf8BytesAndCaseFoldsOnRequest()
    {
        Assert.True(CompareValues.CompareKeys("B", "a", ignoreCase: false) < 0);
        Assert.True(CompareValues.CompareKeys("a", "B", ignoreCase: true) < 0);
        Assert.Equal(0, CompareValues.CompareKeys("Alice", "ALICE", ignoreCase: true));
    }

    [Fact]
    public void SupplementaryCharactersSortAfterThePrivateUseArea()
    {
        // UTF-16 puts the surrogate pair of U+1F600 below U+E000; UTF-8, and a binary collation, put it above.
        Assert.True(CompareValues.CompareUtf8("", "\U0001F600", ignoreCase: false) < 0);
        Assert.True(string.CompareOrdinal("", "\U0001F600") > 0);
    }

    [Fact]
    public void TimestampsAgreeToTheChosenPrecision()
    {
        var a = new DateTime(2024, 5, 1, 10, 0, 0).AddTicks(1_234_567);
        var b = new DateTime(2024, 5, 1, 10, 0, 0).AddTicks(1_234_560);

        Assert.True(CompareValues.AreEqual(a, b, DataCompareOptions.Default));
        Assert.False(CompareValues.AreEqual(a, b, DataCompareOptions.Default with { TimestampFractionalDigits = 7 }));
    }

    [Fact]
    public void TimestampTextFromSqliteMatchesADateTime()
    {
        var value = new DateTime(2024, 5, 1, 10, 30, 0, DateTimeKind.Unspecified);

        Assert.True(CompareValues.AreEqual("2024-05-01 10:30:00", value, DataCompareOptions.Default));
        Assert.True(CompareValues.AreEqual("2024-05-01 10:30:00.000", "2024-05-01T10:30:00", DataCompareOptions.Default));
    }

    [Fact]
    public void BinaryComparesByContent()
    {
        Assert.True(CompareValues.AreEqual(new byte[] { 1, 2 }, new byte[] { 1, 2 }, DataCompareOptions.Default));
        Assert.False(CompareValues.AreEqual(new byte[] { 1, 2 }, new byte[] { 1, 3 }, DataCompareOptions.Default));
        Assert.True(CompareValues.CompareKeys(new byte[] { 1 }, new byte[] { 2 }, ignoreCase: false) < 0);
    }

    [Fact]
    public void GuidMatchesItsText()
    {
        var id = Guid.NewGuid();

        Assert.True(CompareValues.AreEqual(id, id.ToString("D"), DataCompareOptions.Default));
    }

    [Fact]
    public void BooleanMatchesSqliteInteger()
    {
        Assert.True(CompareValues.AreEqual(true, 1L, DataCompareOptions.Default));
        Assert.False(CompareValues.AreEqual(false, 1L, DataCompareOptions.Default));
    }
}
