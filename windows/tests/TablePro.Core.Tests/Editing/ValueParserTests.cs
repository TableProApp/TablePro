using System.Globalization;
using TablePro.Core.Editing;

namespace TablePro.Core.Tests.Editing;

public sealed class ValueParserTests
{
    private static object? Parsed(string? text, Type type)
    {
        Assert.True(ValueParser.TryParse(text, type, out var value), $"'{text}' should parse as {type.Name}");
        return value;
    }

    private static void Fails(string text, Type type)
    {
        Assert.False(ValueParser.TryParse(text, type, out var value), $"'{text}' should not parse as {type.Name}");
        Assert.Null(value);
    }

    [Fact]
    public void NullTextIsNullForAnyType()
    {
        Assert.Null(Parsed(null, typeof(int)));
        Assert.Null(Parsed(null, typeof(string)));
        Assert.Null(Parsed(null, typeof(byte[])));
    }

    [Fact]
    public void StringsPassThroughUntouched() => Assert.Equal("  a b  ", Parsed("  a b  ", typeof(string)));

    [Fact]
    public void UnknownTypesKeepTheText() => Assert.Equal("{\"a\":1}", Parsed("{\"a\":1}", typeof(object)));

    [Fact]
    public void IntegersParseToTheirOwnType()
    {
        Assert.Equal(-42, Parsed("-42", typeof(int)));
        Assert.Equal(9_000_000_000L, Parsed("9000000000", typeof(long)));
        Assert.Equal((short)-5, Parsed("-5", typeof(short)));
        Assert.Equal((byte)255, Parsed("255", typeof(byte)));
        Assert.Equal((sbyte)-128, Parsed("-128", typeof(sbyte)));
        Assert.Equal((ushort)65535, Parsed("65535", typeof(ushort)));
        Assert.Equal(4_000_000_000u, Parsed("4000000000", typeof(uint)));
        Assert.Equal(ulong.MaxValue, Parsed("18446744073709551615", typeof(ulong)));
        Assert.Equal(7, Parsed(" 7 ", typeof(int)));
    }

    [Fact]
    public void NullableTypesParseAsTheirUnderlyingType()
    {
        Assert.Equal(5, Parsed("5", typeof(int?)));
        Assert.Equal(true, Parsed("yes", typeof(bool?)));
    }

    [Theory]
    [InlineData("abc", typeof(int))]
    [InlineData("1.5", typeof(int))]
    [InlineData("1,000", typeof(int))]
    [InlineData("", typeof(int))]
    [InlineData("2147483648", typeof(int))]
    [InlineData("256", typeof(byte))]
    [InlineData("-1", typeof(uint))]
    [InlineData("-1", typeof(ulong))]
    [InlineData("40000", typeof(short))]
    [InlineData("x", typeof(double))]
    [InlineData("1,5", typeof(double))]
    [InlineData("1,5", typeof(decimal))]
    [InlineData("1,000.5", typeof(decimal))]
    [InlineData("x", typeof(float))]
    [InlineData("maybe", typeof(bool))]
    [InlineData("2", typeof(bool))]
    [InlineData("not-a-guid", typeof(Guid))]
    [InlineData("yesterday", typeof(DateTime))]
    [InlineData("2024-13-01", typeof(DateTime))]
    [InlineData("soon", typeof(DateTimeOffset))]
    [InlineData("2024-02-30", typeof(DateOnly))]
    [InlineData("25:00", typeof(TimeOnly))]
    [InlineData("forever", typeof(TimeSpan))]
    [InlineData("zz", typeof(byte[]))]
    [InlineData("0xABC", typeof(byte[]))]
    public void InvalidTextFails(string text, Type type) => Fails(text, type);

    [Fact]
    public void FractionalNumbersUseInvariantCulture()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
        try
        {
            Assert.Equal(1.5m, Parsed("1.5", typeof(decimal)));
            Assert.Equal(1000m, Parsed("1e3", typeof(decimal)));
            Assert.Equal(-0.25, Parsed("-0.25", typeof(double)));
            Assert.Equal(6.02e23, Parsed("6.02E23", typeof(double)));
            Assert.Equal(2.5f, Parsed("2.5", typeof(float)));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Theory]
    [InlineData("1", true)]
    [InlineData("true", true)]
    [InlineData("TRUE", true)]
    [InlineData(" t ", true)]
    [InlineData("Yes", true)]
    [InlineData("y", true)]
    [InlineData("0", false)]
    [InlineData("false", false)]
    [InlineData("F", false)]
    [InlineData("no", false)]
    [InlineData("N", false)]
    public void BooleansAcceptCommonSpellings(string text, bool expected) => Assert.Equal(expected, Parsed(text, typeof(bool)));

    [Fact]
    public void GuidsParse()
    {
        var id = Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e");

        Assert.Equal(id, Parsed("0f8fad5b-d9cb-469f-a165-70867728950e", typeof(Guid)));
        Assert.Equal(id, Parsed("{0F8FAD5B-D9CB-469F-A165-70867728950E}", typeof(Guid)));
    }

    [Fact]
    public void DatesAndTimesParse()
    {
        Assert.Equal(new DateTime(2024, 1, 2, 3, 4, 5), Parsed(" 2024-01-02 03:04:05 ", typeof(DateTime)));
        Assert.Equal(new DateTime(2024, 1, 2), Parsed("2024-01-02", typeof(DateTime)));
        Assert.Equal(
            new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.FromHours(2)),
            Parsed("2024-01-02 03:04:05+02:00", typeof(DateTimeOffset)));
        Assert.Equal(new DateOnly(2024, 2, 29), Parsed("2024-02-29", typeof(DateOnly)));
        Assert.Equal(new TimeOnly(13, 14, 15), Parsed("13:14:15", typeof(TimeOnly)));
        Assert.Equal(new TimeSpan(1, 2, 3, 4), Parsed("1.02:03:04", typeof(TimeSpan)));
    }

    [Theory]
    [InlineData("0AFF", new byte[] { 0x0A, 0xFF })]
    [InlineData("0x0aff", new byte[] { 0x0A, 0xFF })]
    [InlineData(" 0X01 ", new byte[] { 0x01 })]
    [InlineData("", new byte[0])]
    [InlineData("0x", new byte[0])]
    public void HexParsesToBytes(string text, byte[] expected) => Assert.Equal(expected, Parsed(text, typeof(byte[])));
}
