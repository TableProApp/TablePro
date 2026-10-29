using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;
using TablePro.Core.Localization;
using TablePro.Core.Results;

namespace TablePro.Core.Export;

/// <summary>
/// Writes a result as an Excel workbook: the smallest SpreadsheetML package Excel, LibreOffice and Numbers open, one
/// sheet with a bold frozen header row. Rows stream into the zip entry, so a large export never builds the sheet in memory.
/// </summary>
internal static class XlsxWriter
{
    private const string MainNs = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string RelNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    public static async Task WriteAsync(ResultSet result, IReadOnlyList<int>? rows, Stream stream, ExportOptions options, CancellationToken cancellationToken)
    {
        using var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true);
        await WriteEntryAsync(zip, "[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
              <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """, cancellationToken);
        await WriteEntryAsync(zip, "_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """, cancellationToken);
        var sheetName = SheetName(options.TargetTable?.Name ?? CoreStrings.Get("Export/SheetName"));
        await WriteEntryAsync(zip, "xl/workbook.xml", $"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="{MainNs}" xmlns:r="{RelNs}"><sheets><sheet name="{System.Security.SecurityElement.Escape(sheetName)}" sheetId="1" r:id="rId1"/></sheets></workbook>
            """, cancellationToken);
        await WriteEntryAsync(zip, "xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """, cancellationToken);

        // Style 1 is the bold header; style 2 shows a date as yyyy-mm-dd hh:mm:ss.
        await WriteEntryAsync(zip, "xl/styles.xml", $"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="{MainNs}">
              <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts>
              <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
              <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
              <borders count="1"><border/></borders>
              <cellStyleXfs count="1"><xf/></cellStyleXfs>
              <cellXfs count="3"><xf/><xf fontId="1" applyFont="1"/><xf numFmtId="164" applyNumberFormat="1"/></cellXfs>
            </styleSheet>
            """, cancellationToken);

        var entry = zip.CreateEntry("xl/worksheets/sheet1.xml", CompressionLevel.Fastest);
        await using var entryStream = entry.Open();
        await using var writer = XmlWriter.Create(entryStream, new XmlWriterSettings { Async = true, Encoding = new UTF8Encoding(false) });
        await writer.WriteStartDocumentAsync(standalone: true);
        writer.WriteStartElement("worksheet", MainNs);
        writer.WriteRaw("<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>");
        writer.WriteStartElement("sheetData", MainNs);

        var rowNumber = 0;
        if (options.IncludeHeader)
        {
            rowNumber++;
            writer.WriteStartElement("row", MainNs);
            foreach (var column in result.Columns)
            {
                WriteText(writer, column.Name, style: 1);
            }

            writer.WriteEndElement();
        }

        foreach (var row in rows is null ? result.Rows : rows.Select(i => result.Rows[i]))
        {
            writer.WriteStartElement("row", MainNs);
            foreach (var value in row)
            {
                WriteCell(writer, value, options.NullText);
            }

            writer.WriteEndElement();
            if (++rowNumber % 5000 == 0)
            {
                await writer.FlushAsync();
                cancellationToken.ThrowIfCancellationRequested();
            }
        }

        writer.WriteEndElement();
        writer.WriteEndElement();
        await writer.WriteEndDocumentAsync();
        await writer.FlushAsync();
    }

    private static void WriteCell(XmlWriter writer, object? value, string nullText)
    {
        switch (value)
        {
            case null:
                if (nullText.Length > 0)
                {
                    WriteText(writer, nullText, style: 0);
                }
                else
                {
                    writer.WriteStartElement("c", MainNs);
                    writer.WriteEndElement();
                }

                break;
            case bool b:
                writer.WriteStartElement("c", MainNs);
                writer.WriteAttributeString("t", "b");
                writer.WriteElementString("v", MainNs, b ? "1" : "0");
                writer.WriteEndElement();
                break;
            case DateTime dt:
                WriteNumber(writer, dt.ToOADate().ToString("R", CultureInfo.InvariantCulture), style: 2);
                break;
            case DateTimeOffset dto:
                WriteNumber(writer, dto.UtcDateTime.ToOADate().ToString("R", CultureInfo.InvariantCulture), style: 2);
                break;
            case double d when double.IsFinite(d):
                WriteNumber(writer, d.ToString("R", CultureInfo.InvariantCulture), style: 0);
                break;
            case float f when float.IsFinite(f):
                WriteNumber(writer, f.ToString("R", CultureInfo.InvariantCulture), style: 0);
                break;
            case int or long or short or byte or sbyte or ushort or uint or decimal:
                WriteNumber(writer, ((IFormattable)value).ToString(null, CultureInfo.InvariantCulture), style: 0);
                break;
            default:
                // Excel caps a cell at 32,767 characters; a longer value is cut rather than corrupting the sheet.
                var text = CellFormatter.Format(value);
                WriteText(writer, text.Length > 32_767 ? text[..32_767] : text, style: 0);
                break;
        }
    }

    private static void WriteNumber(XmlWriter writer, string number, int style)
    {
        writer.WriteStartElement("c", MainNs);
        if (style != 0)
        {
            writer.WriteAttributeString("s", style.ToString(CultureInfo.InvariantCulture));
        }

        writer.WriteElementString("v", MainNs, number);
        writer.WriteEndElement();
    }

    private static void WriteText(XmlWriter writer, string text, int style)
    {
        writer.WriteStartElement("c", MainNs);
        writer.WriteAttributeString("t", "inlineStr");
        if (style != 0)
        {
            writer.WriteAttributeString("s", style.ToString(CultureInfo.InvariantCulture));
        }

        writer.WriteStartElement("is", MainNs);
        writer.WriteStartElement("t", MainNs);
        writer.WriteAttributeString("xml", "space", null, "preserve");
        writer.WriteString(StripInvalidXml(text));
        writer.WriteEndElement();
        writer.WriteEndElement();
        writer.WriteEndElement();
    }

    private static string StripInvalidXml(string text)
    {
        foreach (var c in text)
        {
            if (!XmlConvert.IsXmlChar(c) && !char.IsSurrogate(c))
            {
                return string.Concat(text.Where(ch => XmlConvert.IsXmlChar(ch) || char.IsSurrogate(ch)));
            }
        }

        return text;
    }

    private static string SheetName(string name)
    {
        var cleaned = string.Concat(name.Where(c => c is not ('\\' or '/' or '?' or '*' or '[' or ']' or ':')));
        return cleaned.Length == 0 ? CoreStrings.Get("Export/SheetName") : cleaned[..Math.Min(31, cleaned.Length)];
    }

    private static async Task WriteEntryAsync(ZipArchive zip, string path, string content, CancellationToken cancellationToken)
    {
        var entry = zip.CreateEntry(path, CompressionLevel.Fastest);
        await using var stream = entry.Open();
        await stream.WriteAsync(Encoding.UTF8.GetBytes(content), cancellationToken);
    }
}
