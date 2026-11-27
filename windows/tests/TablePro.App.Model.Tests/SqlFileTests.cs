using System.Text;

namespace TablePro.App.Model.Tests;

public sealed class SqlFileTests : IDisposable
{
    private const string Text = "select 'caf\u00e9 \u2713 \U0001F600'\r\nfrom t;\r\n";

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-sqlfile-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string QueryFile => Path.Combine(_directory, "query.sql");

    [Fact]
    public void Utf8WithoutAMarkRoundTrips()
    {
        SqlFile.Write(QueryFile, Text, SqlFileFormat.Utf8);

        Assert.Equal(Encoding.UTF8.GetBytes(Text), File.ReadAllBytes(QueryFile));
        var read = SqlFile.Read(QueryFile);
        Assert.Equal(Text, read.Text);
        Assert.Equal(SqlFileFormat.Utf8, read.Format);
    }

    [Fact]
    public void Utf8WithAMarkKeepsIt()
    {
        byte[] stored = [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(Text)];
        File.WriteAllBytes(QueryFile, stored);

        var read = SqlFile.Read(QueryFile);
        SqlFile.Write(QueryFile, read.Text, read.Format);

        Assert.Equal(Text, read.Text);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Utf8, true), read.Format);
        Assert.Equal(stored, File.ReadAllBytes(QueryFile));
    }

    [Fact]
    public void Utf16LittleEndianWithAMarkRoundTrips()
    {
        byte[] stored = [0xFF, 0xFE, .. Encoding.Unicode.GetBytes(Text)];
        File.WriteAllBytes(QueryFile, stored);

        var read = SqlFile.Read(QueryFile);
        SqlFile.Write(QueryFile, read.Text, read.Format);

        Assert.Equal(Text, read.Text);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Utf16LittleEndian, true), read.Format);
        Assert.Equal(stored, File.ReadAllBytes(QueryFile));
    }

    [Fact]
    public void Utf16BigEndianAndUtf32ReadByTheirMarks()
    {
        File.WriteAllBytes(QueryFile, [0xFE, 0xFF, .. Encoding.BigEndianUnicode.GetBytes(Text)]);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Utf16BigEndian, true), SqlFile.Read(QueryFile).Format);

        File.WriteAllBytes(QueryFile, [0xFF, 0xFE, 0x00, 0x00, .. Encoding.UTF32.GetBytes(Text)]);
        var little = SqlFile.Read(QueryFile);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Utf32LittleEndian, true), little.Format);
        Assert.Equal(Text, little.Text);

        var utf32BigEndian = new UTF32Encoding(bigEndian: true, byteOrderMark: false);
        File.WriteAllBytes(QueryFile, [0x00, 0x00, 0xFE, 0xFF, .. utf32BigEndian.GetBytes(Text)]);
        var big = SqlFile.Read(QueryFile);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Utf32BigEndian, true), big.Format);
        Assert.Equal(Text, big.Text);
    }

    [Fact]
    public void BytesThatAreNotUtf8ReadAsLatin1AndSaveBackAsLatin1()
    {
        File.WriteAllBytes(QueryFile, Encoding.Latin1.GetBytes("select 'caf\u00e9';"));

        var read = SqlFile.Read(QueryFile);
        SqlFile.Write(QueryFile, "select 'na\u00efve';", read.Format);

        Assert.Equal("select 'caf\u00e9';", read.Text);
        Assert.Equal(new SqlFileFormat(SqlFileEncoding.Latin1, false), read.Format);
        Assert.Equal(Encoding.Latin1.GetBytes("select 'na\u00efve';"), File.ReadAllBytes(QueryFile));
    }

    [Fact]
    public void ALatin1SaveThatCannotHoldACharacterLeavesTheFileAsItWas()
    {
        var stored = Encoding.Latin1.GetBytes("select 'caf\u00e9';");
        File.WriteAllBytes(QueryFile, stored);
        var format = SqlFile.Read(QueryFile).Format;

        var failure = Assert.Throws<SqlFileEncodingException>(
            () => SqlFile.Write(QueryFile, "select '\U0001F600';", format));

        Assert.Equal("\U0001F600", failure.Character);
        Assert.Equal(SqlFileEncoding.Latin1, failure.FileEncoding);
        Assert.Equal(QueryFile, failure.FilePath);
        Assert.Equal(stored, File.ReadAllBytes(QueryFile));
        Assert.Equal<string>([QueryFile], Directory.GetFiles(_directory));
    }

    [Fact]
    public void AWriteKeepsTheTextsLineEndingsAndLeavesNothingBesideTheFile()
    {
        SqlFile.Write(QueryFile, "a\nb\r\nc\rd", SqlFileFormat.Utf8);
        SqlFile.Write(QueryFile, "a\nb\r\nc\rd e", SqlFileFormat.Utf8);

        Assert.Equal("a\nb\r\nc\rd e", SqlFile.Read(QueryFile).Text);
        Assert.Equal<string>([QueryFile], Directory.GetFiles(_directory));
    }

    [Fact]
    public void TheStampTellsAWriteElsewhereAndAFileThatIsGone()
    {
        var written = SqlFile.Write(QueryFile, "select 1;", SqlFileFormat.Utf8);
        Assert.Equal(written, SqlFile.Stamp(QueryFile));
        Assert.Equal(written, SqlFile.Read(QueryFile).Stamp);

        File.WriteAllText(QueryFile, "select 22;");
        Assert.NotEqual(written, SqlFile.Stamp(QueryFile));

        File.Delete(QueryFile);
        Assert.Null(SqlFile.Stamp(QueryFile));
        Assert.Throws<FileNotFoundException>(() => SqlFile.Read(QueryFile));
    }
}
