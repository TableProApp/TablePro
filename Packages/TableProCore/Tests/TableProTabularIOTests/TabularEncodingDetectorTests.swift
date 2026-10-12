import CoreFoundation
import Foundation
@testable import TableProTabularIO
import XCTest

final class TabularEncodingDetectorTests: XCTestCase {
    private let japaneseRows = """
    商品コード,商品名,在庫管理区分,ｻﾞｲｺｶﾝﾘｸﾌﾞﾝ,備考
    10001,ソフトウェア保守,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,表示のみ
    10002,ポイント交換,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,ー
    10003,髙橋商店の注文,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,①から③まで
    10004,東京都港区芝公園４－２－８,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,～
    10005,山﨑さんの見積書,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,確認済み

    """

    private func encoded(_ text: String, _ encoding: TabularTextEncoding) throws -> Data {
        try XCTUnwrap(text.data(using: encoding.foundationEncoding, allowLossyConversion: false))
    }

    private func sniff(_ data: Data, isWholeFile: Bool = true) -> TabularEncodingSniff {
        TabularEncodingDetector.sniff(data, isWholeFile: isWholeFile)
    }

    func testByteOrderMarksDecideTheEncoding() {
        XCTAssertEqual(sniff(Data([0xEF, 0xBB, 0xBF, 0x61])), TabularEncodingSniff(encoding: .utf8, byteOrderMarkLength: 3))
        XCTAssertEqual(sniff(Data([0xFF, 0xFE, 0x61, 0x00])), TabularEncodingSniff(encoding: .utf16LittleEndian, byteOrderMarkLength: 2))
        XCTAssertEqual(sniff(Data([0xFE, 0xFF, 0x00, 0x61])), TabularEncodingSniff(encoding: .utf16BigEndian, byteOrderMarkLength: 2))
    }

    func testASCIIAndUTF8ReadAsUTF8() {
        XCTAssertEqual(sniff(Data("id,name\n1,Ann\n".utf8)).encoding, .utf8)
        XCTAssertEqual(sniff(Data(japaneseRows.utf8)).encoding, .utf8)
        XCTAssertEqual(sniff(Data()).encoding, .utf8)
    }

    func testShiftJISExportIsDetected() throws {
        XCTAssertEqual(sniff(try encoded(japaneseRows, .shiftJIS)).encoding, .shiftJIS)
    }

    func testHalfWidthKatakanaOnlyReadsAsShiftJIS() throws {
        let screenshotHeader: [UInt8] = [0xBB, 0xDE, 0xB2, 0xBA, 0xB6, 0xDD, 0xD8, 0xB8, 0xCC, 0xDE, 0xDD]
        var bytes = Array("CODE,".utf8) + screenshotHeader + [0x0A]
        let rows = "1,ｻﾞｲｺｶﾝﾘｽﾙ\n2,ﾁｮｳﾘｱﾘ\n3,ｿﾌﾄｳｪｱ\n4,ﾎﾟｲﾝﾄ\n"
        bytes += [UInt8](try encoded(rows, .shiftJIS))
        XCTAssertEqual(sniff(Data(bytes)).encoding, .shiftJIS)
    }

    func testTrailBytesThatSpellBackslashAndPipeStayShiftJIS() throws {
        let text = "名前|読み\nソフト|ｿﾌﾄ\n表計算|ﾋｮｳｹｲｻﾝ\nポイント|ﾎﾟｲﾝﾄ\n"
        XCTAssertEqual(sniff(try encoded(text, .shiftJIS)).encoding, .shiftJIS)
    }

    func testABadByteInTheSampleDoesNotHideTheEncoding() throws {
        var bytes = try encoded(japaneseRows, .shiftJIS)
        bytes.append(contentsOf: Array("10006,".utf8) + [0xA0] + Array(",x\n".utf8))
        bytes.append(try encoded(japaneseRows, .shiftJIS))
        XCTAssertEqual(sniff(bytes).encoding, .shiftJIS)

        var halfWidth = try encoded(String(repeating: "1,ｻﾞｲｺｶﾝﾘｽﾙ,ﾁｮｳﾘｱﾘ\n", count: 60), .shiftJIS)
        halfWidth.append(contentsOf: Array("2,".utf8) + [0xA0] + [0x0A])
        XCTAssertEqual(sniff(halfWidth).encoding, .shiftJIS)
    }

    func testEUCJPIsDetected() throws {
        let text = """
        商品コード,商品名,在庫管理区分,ｻﾞｲｺｶﾝﾘｸﾌﾞﾝ,備考
        10001,ソフトウェア保守,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,表示のみ
        10002,ポイント交換,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,確認中
        10003,高橋商店の注文,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,一から三まで
        10004,東京都港区芝公園,在庫管理しない,ｻﾞｲｺｶﾝﾘｼﾅｲ,発送済み
        10005,山崎さんの見積書,在庫管理する,ｻﾞｲｺｶﾝﾘｽﾙ,確認済み

        """
        XCTAssertEqual(sniff(try encoded(text, .eucJP)).encoding, .eucJP)
    }

    func testSimplifiedChineseIsDetectedAsGB18030() throws {
        let text = """
        客户编号,客户名称,所在城市,备注
        1001,北京科技有限公司,北京市朝阳区,重要客户
        1002,上海贸易集团,上海市浦东新区,需要跟进
        1003,广州电子商务中心,广州市天河区,已经签约

        """
        XCTAssertEqual(sniff(try encoded(text, .gb18030)).encoding, .gb18030)
    }

    func testTraditionalChineseWithWindowsOnlyCharactersIsDetectedAsBig5() throws {
        let text = """
        客戶編號,客戶名稱,所在城市,備註
        2001,臺北科技股份有限公司,臺北市信義區,碁盤裏的重要客戶
        2002,高雄貿易集團,高雄市前鎮區,需要追蹤
        2003,臺中電子商務中心,臺中市西屯區,已經簽約

        """
        let bytes = try encoded(text, .big5)
        XCTAssertNil(String(data: bytes, encoding: Self.strictBig5), "the sample holds cp950-only characters")
        XCTAssertEqual(sniff(bytes).encoding, .big5)
    }

    func testKoreanWithUnifiedHangulIsDetectedAsEUCKR() throws {
        let text = """
        고객번호,고객명,도시,비고
        3001,똠방각하 무역,서울특별시 강남구,중요 고객
        3002,한국전자 주식회사,부산광역시 해운대구,후속 조치 필요
        3003,뷁 상사,대구광역시 수성구,계약 완료

        """
        XCTAssertEqual(sniff(try encoded(text, .eucKR)).encoding, .eucKR)
    }

    func testWesternTextStaysWindows1252() throws {
        let text = """
        Kunde;Ort;Straße;Notiz
        Müller GmbH;München;Hauptstraße 12;“Wichtig” – 5 €
        BÄCKEREI SCHRÖDER;KÖLN;DÜSSELDORFER STR. 5;DEUTSCHLAND
        Société Générale;Genève;Rue du Rhône;Crème brûlée

        """
        XCTAssertEqual(sniff(try encoded(text, .windows1252)).encoding, .windows1252)
    }

    func testShortWesternFilesWithSymbolsAndCapitalsStayWindows1252() throws {
        let samples = [
            "Book,£12.50\nMusic,£9.99\n",
            "Item;Price\nBook;£12.50\nFood;€5.00\n",
            "Name,Note\nACME ©2024,Registered ®\n",
            "SKU1,Item 1,£1.99\n",
            "S1,5 µm\nx,½ in\nx,10 m²\ntemp,20°C\n",
            "KUNDE;ORT\nMÜLLER GMBH;MÜNCHEN\nBÄCKEREI SCHRÖDER;KÖLN\n",
            "NOM;VILLE\nSOCIÉTÉ GÉNÉRALE;GENÈVE\nHÉLÈNE;ORLÉANS\n",
            "id,amount\n1,0\u{A0}234,56 €\n2,1\u{A0}000,00 €\n",
            "id,amount\n1,£5\n2,¥300\n3,€7\n4,¢9\n"
        ]
        for sample in samples {
            XCTAssertEqual(sniff(try encoded(sample, .windows1252)).encoding, .windows1252, sample)
        }
    }

    func testMostlyUTF8WithAStrayByteStaysUTF8() {
        var bytes = Data("name;city\nJürgen Müller;Köln\nStraße;Düsseldorf\n„Zitat“;Größe\n".utf8)
        bytes.append(contentsOf: Array("caf".utf8) + [0xE9] + Array(";x\n".utf8))
        XCTAssertEqual(sniff(bytes).encoding, .utf8)
    }

    func testAGB18030CharacterAcrossTheSampleEdgeIsNotCut() throws {
        let fourByteCharacter: [UInt8] = [0x94, 0x39, 0xFC, 0x36]
        XCTAssertNotNil(String(bytes: fourByteCharacter, encoding: TabularTextEncoding.gb18030.foundationEncoding))
        let row = try encoded("北京市朝阳区建国路八十八号", .gb18030)
        for shift in 0..<4 {
            var bytes = Data()
            while bytes.count < TabularEncodingDetector.sampleLength - shift - 2 {
                bytes.append(row)
            }
            bytes.append(contentsOf: fourByteCharacter)
            bytes.append(row)
            bytes.append(0x0A)
            XCTAssertEqual(sniff(bytes).encoding, .gb18030, "shift \(shift)")
        }
    }

    func testUnmarkedUTF16CJKWithZeroLowBytesIsDetected() throws {
        let texts = [
            String(repeating: "1000,山田\u{3000}太郎,東京都港区芝公園4-2-8,03-1234-5000\n", count: 30),
            String(repeating: "一一一一一一一一一一一一一一一一,一\n", count: 20),
            String(repeating: String(repeating: "漢字", count: 26) + "," + String(repeating: "漢字", count: 12) + "\n", count: 20)
        ]
        for text in texts {
            XCTAssertEqual(sniff(try encoded(text, .utf16LittleEndian)).encoding, .utf16LittleEndian)
            XCTAssertEqual(sniff(try encoded(text, .utf16BigEndian)).encoding, .utf16BigEndian)
        }
    }

    func testAFileEndingInAWesternByteIsNotReadAsUTF8() {
        XCTAssertEqual(sniff(Data([0x6E, 0x0A, 0x43, 0x61, 0x66, 0xE9])).encoding, .windows1252)
    }

    func testUTF16WithoutAByteOrderMarkIsDetected() throws {
        let text = "名前,住所\n吉田,三上\n本田,日本\nAnn,Paris\n"
        XCTAssertEqual(sniff(try encoded(text, .utf16LittleEndian)), TabularEncodingSniff(encoding: .utf16LittleEndian, byteOrderMarkLength: 0))
        XCTAssertEqual(sniff(try encoded(text, .utf16BigEndian)), TabularEncodingSniff(encoding: .utf16BigEndian, byteOrderMarkLength: 0))
    }

    func testShiftJISAfterALongASCIIPrefixIsDetected() throws {
        var bytes = Data(String(repeating: "12345,ABCDE,2024-01-01\n", count: 14_000).utf8)
        XCTAssertGreaterThan(bytes.count, 300_000)
        bytes.append(try encoded(japaneseRows, .shiftJIS))
        XCTAssertEqual(sniff(bytes).encoding, .shiftJIS)
    }

    func testCarriageReturnLinesAreDetected() throws {
        let text = japaneseRows.replacingOccurrences(of: "\n", with: "\r")
        XCTAssertEqual(sniff(try encoded(text, .shiftJIS)).encoding, .shiftJIS)
    }

    func testAPrefixCutInsideACharacterStaysUTF8() {
        let whole = Data(String(repeating: "東京都港区,", count: 20_000).utf8)
        let cut = whole.prefix(TabularEncodingDetector.sampleLength + 1)
        XCTAssertEqual(sniff(Data(cut), isWholeFile: false).encoding, .utf8)
    }

    func testEveryCandidateIsAnEncodingFoundationKnows() {
        for candidate in TabularEncodingDetector.legacyCandidates {
            XCTAssertNotNil(String(data: Data("a".utf8), encoding: candidate.foundationEncoding), "\(candidate)")
        }
    }

    private static let strictBig5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
    )
}
