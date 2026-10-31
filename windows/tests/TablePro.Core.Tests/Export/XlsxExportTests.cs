using System.IO.Compression;
using System.Xml.Linq;
using TablePro.Core.Export;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Export;

public sealed class XlsxExportTests
{
    private static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";

    [Fact]
    public async Task WritesAWorkbookWithTypedCellsAndAHeader()
    {
        var result = new ResultSet(
            [new ResultColumn("id", "int", typeof(int)), new ResultColumn("name", "text", typeof(string)), new ResultColumn("paid", "bool", typeof(bool)), new ResultColumn("at", "timestamp", typeof(DateTime))],
            [[1, "Ana & <Co>", true, new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Unspecified)], [2, null, false, null]]);
        using var stream = new MemoryStream();

        await ResultExporter.WriteAsync(result, null, stream, new ExportOptions(ExportFormat.Xlsx), TestContext.Current.CancellationToken);

        stream.Position = 0;
        using var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        Assert.NotNull(zip.GetEntry("[Content_Types].xml"));
        Assert.NotNull(zip.GetEntry("xl/workbook.xml"));
        using var sheetStream = zip.GetEntry("xl/worksheets/sheet1.xml")!.Open();
        var sheet = XDocument.Load(sheetStream);
        var rows = sheet.Descendants(Main + "row").ToArray();
        Assert.Equal(3, rows.Length);
        Assert.Equal(["id", "name", "paid", "at"], rows[0].Descendants(Main + "t").Select(t => t.Value));

        var cells = rows[1].Elements(Main + "c").ToArray();
        Assert.Equal("1", cells[0].Element(Main + "v")!.Value);
        Assert.Equal("Ana & <Co>", cells[1].Descendants(Main + "t").Single().Value);
        Assert.Equal("b", cells[2].Attribute("t")!.Value);
        Assert.Equal("2", cells[3].Attribute("s")!.Value);
        Assert.Empty(rows[2].Elements(Main + "c").ElementAt(1).Elements());
    }

    [Fact]
    public void XlsxHasItsExtension() => Assert.Equal(".xlsx", ResultExporter.FileExtension(ExportFormat.Xlsx));
}
