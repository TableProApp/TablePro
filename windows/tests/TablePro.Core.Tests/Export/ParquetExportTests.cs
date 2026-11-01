using System.Numerics;
using Parquet;
using Parquet.Schema;
using TablePro.Core.Export;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Export;

public sealed class ParquetExportTests
{
    private static ResultColumn Col(string name, Type type, string? declared = null) => new(name, declared ?? type.Name, type);

    private static async Task<MemoryStream> ExportAsync(ResultSet result, ExportOptions? options = null, IReadOnlyList<int>? rows = null)
    {
        var stream = new MemoryStream();
        await ResultExporter.WriteAsync(result, rows, stream, options ?? new ExportOptions(ExportFormat.Parquet), TestContext.Current.CancellationToken);
        stream.Position = 0;
        return stream;
    }

    private static async Task<T?[]> ReadColumnAsync<T>(Stream stream, string name, int rowGroup = 0)
        where T : struct
    {
        stream.Position = 0;
        await using var reader = await ParquetReader.CreateAsync(stream, new ParquetOptions { UseDateOnlyTypeForDates = true }, leaveStreamOpen: true, TestContext.Current.CancellationToken);
        using var group = reader.OpenRowGroupReader(rowGroup);
        var field = reader.Schema.FindDataField(name);
        var values = new T?[group.RowCount];
        await group.ReadAsync<T>(field, values.AsMemory(), null, TestContext.Current.CancellationToken);
        return values;
    }

    private static async Task<string?[]> ReadStringsAsync(Stream stream, string name)
    {
        stream.Position = 0;
        await using var reader = await ParquetReader.CreateAsync(stream, null, leaveStreamOpen: true, TestContext.Current.CancellationToken);
        using var group = reader.OpenRowGroupReader(0);
        var values = new string?[group.RowCount];
        await group.ReadAsync(reader.Schema.FindDataField(name), values.AsMemory(), null, TestContext.Current.CancellationToken);
        return values;
    }

    private static async Task<IReadOnlyList<DataField>> ReadFieldsAsync(Stream stream)
    {
        stream.Position = 0;
        await using var reader = await ParquetReader.CreateAsync(stream, null, leaveStreamOpen: true, TestContext.Current.CancellationToken);
        return reader.Schema.GetDataFields();
    }

    [Fact]
    public void FileExtensionIsParquet() => Assert.Equal(".parquet", ResultExporter.FileExtension(ExportFormat.Parquet));

    [Fact]
    public void ParquetAndXlsxAreBinary()
    {
        Assert.True(ResultExporter.IsBinary(ExportFormat.Parquet));
        Assert.True(ResultExporter.IsBinary(ExportFormat.Xlsx));
        Assert.False(ResultExporter.IsBinary(ExportFormat.Csv));
    }

    [Fact]
    public async Task WritesTypedNullableColumns()
    {
        var result = new ResultSet(
            [Col("id", typeof(int)), Col("price", typeof(decimal), "numeric(10,2)"), Col("ratio", typeof(double)), Col("active", typeof(bool)), Col("name", typeof(string), "varchar(20)")],
            [
                [1, 9.99m, 0.5, true, "Ann"],
                [2, null, null, null, null],
                [3, 1234.5m, -1.25, false, "Bob"],
            ]);
        using var stream = await ExportAsync(result);

        var fields = await ReadFieldsAsync(stream);
        Assert.Equal(["id", "price", "ratio", "active", "name"], fields.Select(f => f.Name));
        Assert.All(fields, f => Assert.True(f.IsNullable));
        var price = Assert.IsType<DecimalDataField>(fields[1]);
        Assert.Equal((10, 2), (price.Precision, price.Scale));

        Assert.Equal([1L, 2L, 3L], await ReadColumnAsync<long>(stream, "id"));
        Assert.Equal([9.99m, null, 1234.50m], await ReadColumnAsync<decimal>(stream, "price"));
        Assert.Equal([0.5, null, -1.25], await ReadColumnAsync<double>(stream, "ratio"));
        Assert.Equal([true, null, false], await ReadColumnAsync<bool>(stream, "active"));
        Assert.Equal(["Ann", null, "Bob"], await ReadStringsAsync(stream, "name"));
    }

    [Fact]
    public async Task WritesDatesTimestampsAndTimes()
    {
        var when = new DateTime(2024, 3, 9, 13, 45, 30, 123, DateTimeKind.Unspecified);
        var offset = new DateTimeOffset(2024, 3, 9, 13, 0, 0, TimeSpan.FromHours(2));
        var result = new ResultSet(
            [Col("day", typeof(DateTime), "date"), Col("at", typeof(DateTime), "timestamp"), Col("utc", typeof(DateTimeOffset), "timestamptz"), Col("clock", typeof(TimeSpan), "time"), Col("born", typeof(DateOnly), "date")],
            [[new DateTime(2024, 3, 9), when, offset, new TimeSpan(8, 30, 0), new DateOnly(1990, 1, 2)]]);
        using var stream = await ExportAsync(result);

        var fields = await ReadFieldsAsync(stream);
        Assert.False(Assert.IsType<DateTimeDataField>(fields[1]).IsAdjustedToUTC);
        Assert.True(Assert.IsType<DateTimeDataField>(fields[2]).IsAdjustedToUTC);
        Assert.IsType<TimeDataField>(fields[3]);

        Assert.Equal(new DateOnly(2024, 3, 9), (await ReadColumnAsync<DateOnly>(stream, "day"))[0]);
        Assert.Equal(when, (await ReadColumnAsync<DateTime>(stream, "at"))[0]);
        Assert.Equal(offset.UtcDateTime, (await ReadColumnAsync<DateTime>(stream, "utc"))[0]);
        Assert.Equal(new TimeSpan(8, 30, 0).Ticks / TimeSpan.TicksPerMicrosecond, (await ReadColumnAsync<long>(stream, "clock"))[0]);
        Assert.Equal(new DateOnly(1990, 1, 2), (await ReadColumnAsync<DateOnly>(stream, "born"))[0]);
    }

    [Fact]
    public async Task TextValuesAreCastToTheDeclaredTypeAndUnreadableOnesBecomeNull()
    {
        // A REST driver hands every value over as text; the declared type still decides the column, as on macOS.
        var result = new ResultSet(
            [Col("n", typeof(string), "BIGINT"), Col("flag", typeof(string), "boolean")],
            [["42", "true"], ["not a number", "maybe"], [null, "0"]]);
        using var stream = await ExportAsync(result);

        Assert.Equal([42L, null, null], await ReadColumnAsync<long>(stream, "n"));
        Assert.Equal([true, null, false], await ReadColumnAsync<bool>(stream, "flag"));
    }

    [Fact]
    public async Task BinaryAndOtherValuesKeepTheirContent()
    {
        var id = Guid.Parse("4b2f8a1e-0c5d-4c1a-9b7e-2f6d3a8c9e01");
        var result = new ResultSet(
            [Col("blob", typeof(byte[])), Col("uuid", typeof(Guid)), Col("huge", typeof(BigInteger))],
            [[new byte[] { 1, 2, 3 }, id, BigInteger.Parse("123456789012345678901234567890", System.Globalization.CultureInfo.InvariantCulture)]]);
        using var stream = await ExportAsync(result);

        Assert.Equal(id.ToString(), (await ReadStringsAsync(stream, "uuid"))[0]);
        Assert.Equal("123456789012345678901234567890", (await ReadStringsAsync(stream, "huge"))[0]);
        stream.Position = 0;
        await using var reader = await ParquetReader.CreateAsync(stream, null, leaveStreamOpen: true, TestContext.Current.CancellationToken);
        using var group = reader.OpenRowGroupReader(0);
        var blobs = new byte[]?[1];
        await group.ReadAsync(reader.Schema.FindDataField("blob"), blobs.AsMemory(), null, TestContext.Current.CancellationToken);
        Assert.Equal([1, 2, 3], blobs[0]);
    }

    [Fact]
    public async Task SplitsRowsIntoRowGroupsAndHonorsTheRowSelection()
    {
        var rows = Enumerable.Range(0, 10).Select(i => new object?[] { i }).ToList();
        var result = new ResultSet([Col("n", typeof(int))], rows);
        using var stream = await ExportAsync(result, new ExportOptions(ExportFormat.Parquet, ParquetRowGroupSize: 4), rows: [9, 8, 7, 6, 5]);

        await using (var reader = await ParquetReader.CreateAsync(stream, null, leaveStreamOpen: true, TestContext.Current.CancellationToken))
        {
            Assert.Equal(2, reader.RowGroupCount);
        }

        Assert.Equal([9L, 8L, 7L, 6L], await ReadColumnAsync<long>(stream, "n", 0));
        Assert.Equal([5L], await ReadColumnAsync<long>(stream, "n", 1));
    }

    [Theory]
    [InlineData(ParquetCompression.Snappy)]
    [InlineData(ParquetCompression.Zstd)]
    [InlineData(ParquetCompression.Gzip)]
    [InlineData(ParquetCompression.None)]
    public async Task EveryCompressionReadsBack(ParquetCompression compression)
    {
        var rows = Enumerable.Range(0, 500).Select(i => new object?[] { "value " + (i % 7) }).ToList();
        using var stream = await ExportAsync(new ResultSet([Col("s", typeof(string))], rows), new ExportOptions(ExportFormat.Parquet, ParquetCompression: compression));
        var values = await ReadStringsAsync(stream, "s");
        Assert.Equal(500, values.Length);
        Assert.Equal("value 3", values[10]);
    }

    [Fact]
    public async Task EmptyResultWritesTheSchemaOnly()
    {
        using var stream = await ExportAsync(new ResultSet([Col("id", typeof(long))], []));
        await using var reader = await ParquetReader.CreateAsync(stream, null, leaveStreamOpen: true, TestContext.Current.CancellationToken);
        Assert.Equal(0, reader.RowGroupCount);
        Assert.Equal("id", Assert.Single(reader.Schema.GetDataFields()).Name);
    }

    [Fact]
    public async Task DuplicateAndBlankColumnNamesAreMadeUnique()
    {
        var result = new ResultSet([Col("id", typeof(int)), Col("id", typeof(int)), Col("", typeof(int))], [[1, 2, 3]]);
        using var stream = await ExportAsync(result);
        Assert.Equal(["id", "id_2", "column_3"], (await ReadFieldsAsync(stream)).Select(f => f.Name));
    }

    [Fact]
    public async Task ResultWithoutColumnsIsRefused()
    {
        using var stream = new MemoryStream();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ResultExporter.WriteAsync(new ResultSet([], []), null, stream, new ExportOptions(ExportFormat.Parquet), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("integer", typeof(object), ParquetColumnKind.Int64, 0, 0)]
    [InlineData("NUMERIC(12,3)", typeof(decimal), ParquetColumnKind.Decimal, 12, 3)]
    [InlineData("numeric(10)", typeof(decimal), ParquetColumnKind.Int64, 0, 0)]
    [InlineData("numeric", typeof(decimal), ParquetColumnKind.Double, 0, 0)]
    [InlineData("numeric(38,2)", typeof(decimal), ParquetColumnKind.Double, 0, 0)]
    [InlineData("Nullable(Decimal(18, 4))", typeof(string), ParquetColumnKind.Decimal, 18, 4)]
    [InlineData("TIMESTAMP WITH TIME ZONE", typeof(string), ParquetColumnKind.Timestamp, 0, 0)]
    [InlineData("date", typeof(DateTime), ParquetColumnKind.Date, 0, 0)]
    [InlineData("datetime", typeof(DateTime), ParquetColumnKind.Timestamp, 0, 0)]
    [InlineData("interval", typeof(TimeSpan), ParquetColumnKind.Text, 0, 0)]
    [InlineData("int unsigned", typeof(ulong), ParquetColumnKind.Decimal, 20, 0)]
    [InlineData("bytea", typeof(object), ParquetColumnKind.Binary, 0, 0)]
    [InlineData("jsonb", typeof(string), ParquetColumnKind.Text, 0, 0)]
    public void MapsColumnTypes(string declared, Type clrType, ParquetColumnKind kind, int precision, int scale) =>
        Assert.Equal(new ParquetColumnType(kind, precision, scale), ParquetTypeMapper.Map(new ResultColumn("c", declared, clrType), PostgreSqlDialect.Instance));

    [Fact]
    public void SqliteIgnoresDeclaredPrecisionAndSqlServerMoneyIsFixedPoint()
    {
        Assert.Equal(ParquetColumnKind.Double, ParquetTypeMapper.FromDeclaredType("NUMERIC(10,2)", SqliteDialect.Instance).Kind);
        Assert.Equal(new ParquetColumnType(ParquetColumnKind.Decimal, 19, 4), ParquetTypeMapper.FromDeclaredType("money", SqlServerDialect.Instance));
        Assert.Equal(ParquetColumnKind.Text, ParquetTypeMapper.FromDeclaredType("money", PostgreSqlDialect.Instance).Kind);
    }

    [Fact]
    public void DecimalValuesPastTheirPrecisionBecomeNull()
    {
        Assert.Equal(123.46m, ParquetValues.ToDecimal(123.456m, 5, 2));
        Assert.Null(ParquetValues.ToDecimal(1234.5m, 5, 2));
        Assert.Equal(7m, ParquetValues.ToDecimal("7", 5, 2));
        Assert.Null(ParquetValues.ToDecimal("seven", 5, 2));
    }
}
