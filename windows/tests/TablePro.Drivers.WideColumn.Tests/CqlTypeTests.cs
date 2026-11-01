using System.Net;
using System.Numerics;
using Cassandra;
using TablePro.Drivers.Cassandra;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class CqlTypeTests
{
    [Fact]
    public void FormatsNestedTypesAsDescribeDoes()
    {
        var map = new MapColumnInfo { KeyTypeCode = ColumnTypeCode.Text, ValueTypeCode = ColumnTypeCode.List, ValueTypeInfo = new ListColumnInfo { ValueTypeCode = ColumnTypeCode.Int } };
        var tuple = new TupleColumnInfo { Elements = [new ColumnDesc { TypeCode = ColumnTypeCode.Uuid }, new ColumnDesc { TypeCode = ColumnTypeCode.Varchar }] };
        var vector = new VectorColumnInfo { ValueTypeCode = ColumnTypeCode.Float, Dimensions = 3 };

        Assert.Equal("map<text, list<int>>", CqlTypeNames.Format(ColumnTypeCode.Map, map));
        Assert.Equal("tuple<uuid, text>", CqlTypeNames.Format(ColumnTypeCode.Tuple, tuple));
        Assert.Equal("set<timeuuid>", CqlTypeNames.Format(ColumnTypeCode.Set, new SetColumnInfo { KeyTypeCode = ColumnTypeCode.Timeuuid }));
        Assert.Equal("address", CqlTypeNames.Format(ColumnTypeCode.Udt, new UdtColumnInfo("shop.address")));
        Assert.Equal("vector<float, 3>", CqlTypeNames.Format(ColumnTypeCode.Custom, vector));
        Assert.Equal("smallint", CqlTypeNames.Format(ColumnTypeCode.SmallInt, null));
    }

    [Theory]
    [InlineData(ColumnTypeCode.Uuid, typeof(Guid))]
    [InlineData(ColumnTypeCode.Timeuuid, typeof(Guid))]
    [InlineData(ColumnTypeCode.Varint, typeof(BigInteger))]
    [InlineData(ColumnTypeCode.Decimal, typeof(decimal))]
    [InlineData(ColumnTypeCode.Inet, typeof(string))]
    [InlineData(ColumnTypeCode.Timestamp, typeof(DateTimeOffset))]
    [InlineData(ColumnTypeCode.Date, typeof(DateOnly))]
    [InlineData(ColumnTypeCode.Time, typeof(TimeOnly))]
    [InlineData(ColumnTypeCode.TinyInt, typeof(sbyte))]
    [InlineData(ColumnTypeCode.Counter, typeof(long))]
    [InlineData(ColumnTypeCode.Map, typeof(string))]
    [InlineData(ColumnTypeCode.Udt, typeof(string))]
    [InlineData(ColumnTypeCode.Blob, typeof(byte[]))]
    public void MapsEachCqlTypeToTheClrTypeTheGridEditsWith(ColumnTypeCode code, Type expected) =>
        Assert.Equal(expected, CqlCellMapper.ClrTypeFor(code));

    [Fact]
    public void DecodesFixedWidthScalars()
    {
        Assert.Equal(-2, CqlValueDecoder.Decode([0xFF, 0xFF, 0xFF, 0xFE], ColumnTypeCode.Int, null));
        Assert.Equal(258L, CqlValueDecoder.Decode([0, 0, 0, 0, 0, 0, 1, 2], ColumnTypeCode.Bigint, null));
        Assert.Equal((short)-1, CqlValueDecoder.Decode([0xFF, 0xFF], ColumnTypeCode.SmallInt, null));
        Assert.Equal((sbyte)-128, CqlValueDecoder.Decode([0x80], ColumnTypeCode.TinyInt, null));
        Assert.Equal(true, CqlValueDecoder.Decode([1], ColumnTypeCode.Boolean, null));
        Assert.Equal(1.5d, CqlValueDecoder.Decode([0x3F, 0xF8, 0, 0, 0, 0, 0, 0], ColumnTypeCode.Double, null));
        Assert.Equal("héllo", CqlValueDecoder.Decode("héllo"u8, ColumnTypeCode.Text, null));
        Assert.Equal("", CqlValueDecoder.Decode([], ColumnTypeCode.Text, null));
        Assert.Null(CqlValueDecoder.Decode([], ColumnTypeCode.Int, null));
    }

    [Fact]
    public void DecodesUuidsInNetworkByteOrder()
    {
        byte[] bytes = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];

        Assert.Equal(Guid.Parse("00112233-4455-6677-8899-aabbccddeeff"), CqlValueDecoder.Decode(bytes, ColumnTypeCode.Uuid, null));
    }

    [Fact]
    public void DecodesVarintAndDecimalExactly()
    {
        Assert.Equal(new BigInteger(12345), CqlValueDecoder.Decode([0x30, 0x39], ColumnTypeCode.Varint, null));
        Assert.Equal(new BigInteger(-1), CqlValueDecoder.Decode([0xFF], ColumnTypeCode.Varint, null));
        Assert.Equal(123.45m, CqlValueDecoder.Decode([0, 0, 0, 2, 0x30, 0x39], ColumnTypeCode.Decimal, null));
        Assert.Equal(-1.5m, CqlValueDecoder.Decode([0, 0, 0, 1, 0xF1], ColumnTypeCode.Decimal, null));

        // A scale past System.Decimal's 28 digits stays exact as text.
        Assert.Equal("0." + new string('0', 39) + "7", CqlValueDecoder.Decode([0, 0, 0, 40, 0x07], ColumnTypeCode.Decimal, null));
        Assert.Equal("12300", CqlValueDecoder.FormatDecimal(123, -2));
        Assert.Equal("-0.05", CqlValueDecoder.FormatDecimal(-5, 2));
    }

    [Fact]
    public void DecodesDatesTimesAndAddresses()
    {
        Assert.Equal(new DateOnly(1970, 1, 2), CqlValueDecoder.Decode([0x80, 0, 0, 1], ColumnTypeCode.Date, null));
        Assert.Equal(new DateOnly(1969, 12, 31), CqlValueDecoder.Decode([0x7F, 0xFF, 0xFF, 0xFF], ColumnTypeCode.Date, null));
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1000), CqlValueDecoder.Decode([0, 0, 0, 0, 0, 0, 0x03, 0xE8], ColumnTypeCode.Timestamp, null));
        Assert.Equal(new TimeOnly(0, 0, 1), CqlValueDecoder.Decode([0, 0, 0, 0, 0x3B, 0x9A, 0xCA, 0x00], ColumnTypeCode.Time, null));
        Assert.Equal("10.0.0.1", CqlValueDecoder.Decode([10, 0, 0, 1], ColumnTypeCode.Inet, null));
    }

    [Fact]
    public void DecodesDurationVints()
    {
        Assert.Equal(new Duration(1, 2, 3).ToString(), CqlValueDecoder.Decode([0x02, 0x04, 0x06], ColumnTypeCode.Duration, null));

        var offset = 0;
        Assert.Equal(600UL, CqlValueDecoder.ReadUnsignedVint([0x82, 0x58], ref offset));
        Assert.Equal(2, offset);
    }

    [Fact]
    public void DecodesCollectionsTuplesAndUdtsRecursively()
    {
        byte[] list = [0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 2];
        var decodedList = Assert.IsType<List<object?>>(CqlValueDecoder.Decode(list, ColumnTypeCode.List, new ListColumnInfo { ValueTypeCode = ColumnTypeCode.Int }));
        Assert.Equal([1, 2], decodedList.Cast<int>());

        byte[] map = [0, 0, 0, 1, 0, 0, 0, 1, (byte)'a', 0xFF, 0xFF, 0xFF, 0xFF];
        var decodedMap = Assert.IsType<CqlMapValue>(CqlValueDecoder.Decode(map, ColumnTypeCode.Map, new MapColumnInfo { KeyTypeCode = ColumnTypeCode.Text, ValueTypeCode = ColumnTypeCode.Int }));
        Assert.Equal("a", decodedMap.Entries[0].Key);
        Assert.Null(decodedMap.Entries[0].Value);

        var udt = new UdtColumnInfo("shop.address");
        udt.Fields.Add(new ColumnDesc { Name = "street", TypeCode = ColumnTypeCode.Text });
        udt.Fields.Add(new ColumnDesc { Name = "zip", TypeCode = ColumnTypeCode.Int });

        // A value written before "zip" was added ends after "street".
        var value = CqlValueDecoder.DecodeUdt([0, 0, 0, 2, (byte)'M', (byte)'n'], udt);
        Assert.Equal("shop.address", value.TypeName);
        Assert.Equal([new("street", "Mn"), new("zip", null)], value.Fields);
    }

    [Fact]
    public void MapsDriverValuesToCells()
    {
        var timeUuid = TimeUuid.NewId();
        Assert.Equal(timeUuid.ToGuid(), CqlCellMapper.ToCell(timeUuid));
        Assert.Equal("192.168.1.1", CqlCellMapper.ToCell(IPAddress.Parse("192.168.1.1")));
        Assert.Equal(new DateOnly(2024, 2, 29), CqlCellMapper.ToCell(new LocalDate(2024, 2, 29)));
        Assert.Equal(new TimeOnly(13, 14, 15), CqlCellMapper.ToCell(new LocalTime(13, 14, 15, 0)));
        Assert.Equal(new Duration(0, 1, 0).ToString(), CqlCellMapper.ToCell(new Duration(0, 1, 0)));
        Assert.Equal(new BigInteger(7), CqlCellMapper.ToCell(new BigInteger(7)));
        Assert.Null(CqlCellMapper.ToCell(null));
    }

    [Fact]
    public void WritesCompositesAsJsonFromJsonReadsBack()
    {
        Assert.Equal("[1,2,3]", CqlCellMapper.ToCell(new List<int> { 1, 2, 3 }));
        Assert.Equal("{\"a\":1,\"b\":2}", CqlCellMapper.ToCell(new SortedDictionary<string, int> { ["b"] = 2, ["a"] = 1 }));
        Assert.Equal("{\"1\":\"x\"}", CqlCellMapper.ToCell(new Dictionary<int, string> { [1] = "x" }));
        Assert.Equal("[1,\"a\",null]", CqlCellMapper.ToCell(new Tuple<int, string, string?>(1, "a", null)));
        Assert.Equal("[\"0x0aff\"]", CqlCellMapper.ToCell(new List<byte[]> { new byte[] { 0x0A, 0xFF } }));

        var guid = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");
        var udt = new CqlUdtValue("shop.addr", [
            new("street", "Main"),
            new("tags", new CqlMapValue([new(guid, 1.5m)])),
            new("at", new DateTimeOffset(2024, 1, 2, 3, 4, 5, 6, TimeSpan.FromHours(2))),
            new("n", BigInteger.Parse("123456789012345678901234567890")),
        ]);

        Assert.Equal(
            "{\"street\":\"Main\",\"tags\":{\"00112233-4455-6677-8899-aabbccddeeff\":1.5},\"at\":\"2024-01-02 01:04:05.006+0000\",\"n\":123456789012345678901234567890}",
            CqlCellMapper.ToCell(udt));
    }

    [Fact]
    public void WritesNonFiniteFloatsAsStrings() =>
        Assert.Equal("[\"NaN\",1.5]", CqlCellMapper.ToJson(new[] { double.NaN, 1.5 }));
}
