using System.Text;
using TablePro.Core.Import;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Import;

/// <summary>The macOS app's <c>TabularEncodingDetectorTests</c>, and the SQL import's choice of encoding built on it.</summary>
public sealed class TextEncodingDetectorTests
{
    private const string JapaneseRows = """
        商品コード,商品名,在庫管理区分,ｻﾞｲｺｶﾝﾘｸﾌﾞﾝ,備考
        10001,ソフトウェア保守,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,表示のみ
        10002,ポイント交換,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,ー
        10003,髙橋商店の注文,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,①から③まで
        10004,東京都港区芝公園４－２－８,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,～
        10005,山﨑さんの見積書,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,確認済み

        """;

    static TextEncodingDetectorTests() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    private static byte[] Encoded(string text, int codePage) =>
        Encoding.GetEncoding(codePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetBytes(text.ReplaceLineEndings("\n"));

    private static DetectedTextEncoding Sniff(byte[] bytes, bool isWholeFile = true) => TextEncodingDetector.Sniff(bytes, isWholeFile).Encoding;

    [Fact]
    public void ByteOrderMarksDecideTheEncoding()
    {
        Assert.Equal(new TextEncodingSniff(DetectedTextEncoding.Utf8, 3), TextEncodingDetector.Sniff([0xEF, 0xBB, 0xBF, 0x61]));
        Assert.Equal(new TextEncodingSniff(DetectedTextEncoding.Utf16LittleEndian, 2), TextEncodingDetector.Sniff([0xFF, 0xFE, 0x61, 0x00]));
        Assert.Equal(new TextEncodingSniff(DetectedTextEncoding.Utf16BigEndian, 2), TextEncodingDetector.Sniff([0xFE, 0xFF, 0x00, 0x61]));
    }

    [Fact]
    public void AsciiAndUtf8ReadAsUtf8()
    {
        Assert.Equal(DetectedTextEncoding.Utf8, Sniff(Encoding.UTF8.GetBytes("id,name\n1,Ann\n")));
        Assert.Equal(DetectedTextEncoding.Utf8, Sniff(Encoding.UTF8.GetBytes(JapaneseRows)));
        Assert.Equal(DetectedTextEncoding.Utf8, Sniff([]));
    }

    [Fact]
    public void ShiftJisExportIsDetected() => Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(Encoded(JapaneseRows, 932)));

    [Fact]
    public void HalfWidthKatakanaOnlyReadsAsShiftJis()
    {
        byte[] header = [0xBB, 0xDE, 0xB2, 0xBA, 0xB6, 0xDD, 0xD8, 0xB8, 0xCC, 0xDE, 0xDD];
        byte[] bytes = [.. "CODE,"u8, .. header, 0x0A, .. Encoded("1,ｻﾞｲｺｶﾝﾘｽﾙ\n2,ﾁｮｳﾘｱﾘ\n3,ｿﾌﾄｳｪｱ\n4,ﾎﾟｲﾝﾄ\n", 932)];
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(bytes));
    }

    [Fact]
    public void TrailBytesThatSpellBackslashAndPipeStayShiftJis() =>
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(Encoded("名前|読み\nソフト|ｿﾌﾄ\n表計算|ﾋｮｳｹｲｻﾝ\nポイント|ﾎﾟｲﾝﾄ\n", 932)));

    [Fact]
    public void ABadByteInTheSampleDoesNotHideTheEncoding()
    {
        byte[] bytes = [.. Encoded(JapaneseRows, 932), .. "10006,"u8, 0xA0, .. ",x\n"u8, .. Encoded(JapaneseRows, 932)];
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(bytes));

        byte[] halfWidth = [.. Encoded(string.Concat(Enumerable.Repeat("1,ｻﾞｲｺｶﾝﾘｽﾙ,ﾁｮｳﾘｱﾘ\n", 60)), 932), .. "2,"u8, 0xA0, 0x0A];
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(halfWidth));
    }

    [Fact]
    public void EucJpIsDetected()
    {
        const string text = """
            商品コード,商品名,在庫管理区分,ｻﾞｲｺｶﾝﾘｸﾌﾞﾝ,備考
            10001,ソフトウェア保守,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,表示のみ
            10002,ポイント交換,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,確認中
            10003,高橋商店の注文,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,一から三まで
            10004,東京都港区芝公園,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,発送済み
            10005,山崎さんの見積書,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,確認済み

            """;
        Assert.Equal(DetectedTextEncoding.EucJp, Sniff(Encoded(text, 51932)));
    }

    [Fact]
    public void SimplifiedChineseIsDetectedAsGb18030()
    {
        const string text = """
            客户编号,客户名称,所在城市,备注
            1001,北京科技有限公司,北京市朝阳区,重要客户
            1002,上海贸易集团,上海市浦东新区,需要跟进
            1003,广州电子商务中心,广州市天河区,已经签约

            """;
        Assert.Equal(DetectedTextEncoding.Gb18030, Sniff(Encoded(text, 54936)));
    }

    [Fact]
    public void TraditionalChineseWithWindowsOnlyCharactersIsDetectedAsBig5()
    {
        const string text = """
            客戶編號,客戶名稱,所在城市,備註
            2001,臺北科技股份有限公司,臺北市信義區,碁盤裏的重要客戶
            2002,高雄貿易集團,高雄市前鎮區,需要追蹤
            2003,臺中電子商務中心,臺中市西屯區,已經簽約

            """;
        Assert.Equal(DetectedTextEncoding.Big5, Sniff(Encoded(text, 950)));
    }

    [Fact]
    public void KoreanWithUnifiedHangulIsDetectedAsEucKr()
    {
        const string text = """
            고객번호,고객명,도시,비고
            3001,똠방각하 무역,서울특별시 강남구,중요 고객
            3002,한국전자 주식회사,부산광역시 해운대구,후속 조치 필요
            3003,뷁 상사,대구광역시 수성구,계약 완료

            """;
        Assert.Equal(DetectedTextEncoding.EucKr, Sniff(Encoded(text, 949)));
    }

    [Fact]
    public void WesternTextStaysWindows1252()
    {
        const string text = """
            Kunde;Ort;Straße;Notiz
            Müller GmbH;München;Hauptstraße 12;“Wichtig” – 5 €
            BÄCKEREI SCHRÖDER;KÖLN;DÜSSELDORFER STR. 5;DEUTSCHLAND
            Société Générale;Genève;Rue du Rhône;Crème brûlée

            """;
        Assert.Equal(DetectedTextEncoding.Windows1252, Sniff(Encoded(text, 1252)));
    }

    [Theory]
    [InlineData("Book,£12.50\nMusic,£9.99\n")]
    [InlineData("Item;Price\nBook;£12.50\nFood;€5.00\n")]
    [InlineData("Name,Note\nACME ©2024,Registered ®\n")]
    [InlineData("SKU1,Item 1,£1.99\n")]
    [InlineData("S1,5 µm\nx,½ in\nx,10 m²\ntemp,20°C\n")]
    [InlineData("KUNDE;ORT\nMÜLLER GMBH;MÜNCHEN\nBÄCKEREI SCHRÖDER;KÖLN\n")]
    [InlineData("NOM;VILLE\nSOCIÉTÉ GÉNÉRALE;GENÈVE\nHÉLÈNE;ORLÉANS\n")]
    [InlineData("id,amount\n1,0\xA0" + "234,56 €\n2,1\xA0" + "000,00 €\n")]
    [InlineData("id,amount\n1,£5\n2,¥300\n3,€7\n4,¢9\n")]
    public void ShortWesternFilesWithSymbolsAndCapitalsStayWindows1252(string sample) =>
        Assert.Equal(DetectedTextEncoding.Windows1252, Sniff(Encoded(sample, 1252)));

    [Fact]
    public void MostlyUtf8WithAStrayByteStaysUtf8()
    {
        byte[] bytes = [.. Encoding.UTF8.GetBytes("name;city\nJürgen Müller;Köln\nStraße;Düsseldorf\n„Zitat“;Größe\n"), .. "caf"u8, 0xE9, .. ";x\n"u8];
        Assert.Equal(DetectedTextEncoding.Utf8, Sniff(bytes));
    }

    [Fact]
    public void AGb18030CharacterAcrossTheSampleEdgeIsNotCut()
    {
        byte[] fourByteCharacter = [0x94, 0x39, 0xFC, 0x36];
        var row = Encoded("北京市朝阳区建国路八十八号", 54936);
        for (var shift = 0; shift < 4; shift++)
        {
            var bytes = new List<byte>();
            while (bytes.Count < TextEncodingDetector.SampleLength - shift - 2)
            {
                bytes.AddRange(row);
            }

            bytes.AddRange(fourByteCharacter);
            bytes.AddRange(row);
            bytes.Add(0x0A);
            Assert.Equal(DetectedTextEncoding.Gb18030, Sniff([.. bytes]));
        }
    }

    [Fact]
    public void Utf16WithoutAByteOrderMarkIsDetected()
    {
        const string text = "名前,住所\n吉田,三上\n本田,日本\nAnn,Paris\n";
        Assert.Equal(new TextEncodingSniff(DetectedTextEncoding.Utf16LittleEndian, 0), TextEncodingDetector.Sniff(Encoding.Unicode.GetBytes(text)));
        Assert.Equal(new TextEncodingSniff(DetectedTextEncoding.Utf16BigEndian, 0), TextEncodingDetector.Sniff(Encoding.BigEndianUnicode.GetBytes(text)));
    }

    [Fact]
    public void AFileEndingInAWesternByteIsNotReadAsUtf8() =>
        Assert.Equal(DetectedTextEncoding.Windows1252, Sniff([0x6E, 0x0A, 0x43, 0x61, 0x66, 0xE9]));

    [Fact]
    public void ShiftJisAfterALongAsciiPrefixIsDetected()
    {
        byte[] bytes = [.. Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat("12345,ABCDE,2024-01-01\n", 14_000))), .. Encoded(JapaneseRows, 932)];
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(bytes));
    }

    [Fact]
    public void CarriageReturnLinesAreDetected() =>
        Assert.Equal(DetectedTextEncoding.ShiftJis, Sniff(Encoded(JapaneseRows.ReplaceLineEndings("\n").Replace('\n', '\r'), 932)));

    [Fact]
    public void APrefixCutInsideACharacterStaysUtf8()
    {
        var whole = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("東京都港区,", 20_000)));
        Assert.Equal(DetectedTextEncoding.Utf8, Sniff(whole[..(TextEncodingDetector.SampleLength + 1)], isWholeFile: false));
    }

    [Fact]
    public void TheSqlImportOpensOnTheRememberedEncodingWhenItReadsTheFile()
    {
        var latin = SqlImportEncoding.Find("Latin1")!;
        var choice = SqlImportEncodingChoice.Choose(Encoded("INSERT INTO t VALUES ('Müller');\n", 1252), true, latin, SqliteDialect.Instance);
        Assert.Equal(new SqlImportEncodingChoice(latin, false), choice);
    }

    [Fact]
    public void TheSqlImportGuessesFromTheBytesWhenTheRememberedEncodingFails()
    {
        var choice = SqlImportEncodingChoice.Choose(Encoded("INSERT INTO t VALUES ('Müller', 'Köln', 'Straße');\n", 1252), true, SqlImportEncoding.Utf8, SqliteDialect.Instance);
        Assert.Equal(new SqlImportEncodingChoice(SqlImportEncoding.Find("Windows-1252")!, true), choice);
    }

    [Fact]
    public void TheSqlImportNeverGuessesAnEncodingThatCanHideABackslash()
    {
        // Shift JIS is what the bytes look like, but its trail bytes can be a backslash, so the import keeps UTF-8.
        var choice = SqlImportEncodingChoice.Choose(Encoded("INSERT INTO t VALUES ('" + JapaneseRows.Replace("'", "", StringComparison.Ordinal) + "');\n", 932), true, SqlImportEncoding.Utf8, SqliteDialect.Instance);
        Assert.Equal(new SqlImportEncodingChoice(SqlImportEncoding.Utf8, false), choice);
    }

    [Fact]
    public void ADeclaredEncodingWinsWhenItReadsTheFile()
    {
        var dump = Encoded("/*!40101 SET NAMES latin1 */;\nINSERT INTO t VALUES ('Müller');\n", 1252);
        var choice = SqlImportEncodingChoice.Choose(dump, true, SqlImportEncoding.Utf8, MySqlDialect.Instance);
        Assert.Equal(new SqlImportEncodingChoice(SqlImportEncoding.Find("Windows-1252")!, true), choice);
    }

    [Fact]
    public void ACharacterCutAtThePreviewsEndStillDecodes()
    {
        var bytes = Encoding.UTF8.GetBytes("SELECT '東京';");
        Assert.True(SqlImportEncoding.Utf8.Decodes(bytes.AsSpan(0, 10), isWholeFile: false));
        Assert.False(SqlImportEncoding.Utf8.Decodes(bytes.AsSpan(0, 10), isWholeFile: true));
    }
}
