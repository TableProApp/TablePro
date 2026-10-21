import Foundation
@testable import TableProUtilities
import Testing

struct FileTextLoaderWideDecodeTests {
    @Test("A blob read under a UTF-16 or UTF-32 working copy decodes in that encoding, not as UTF-8 with NULs", arguments: [
        String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
    ])
    func wideDeclaredEncodingWins(encoding: String.Encoding) throws {
        let text = "SELECT id FROM customers;\n"
        let bytes = try #require(text.data(using: encoding))
        #expect(String(data: bytes, encoding: .utf8) != nil)

        #expect(FileTextLoader.decode(bytes, declaredEncoding: encoding) == text)
    }

    @Test("A UTF-16 blob with no working copy left to name its encoding still decodes as UTF-16")
    func wideBlobWithoutDeclaredEncoding() throws {
        let text = "SELECT id FROM customers;\n"
        let bytes = try #require(text.data(using: .utf16LittleEndian))

        #expect(FileTextLoader.decode(bytes) == text)
        #expect(FileTextLoader.unmarkedWideEncoding(of: bytes) == .utf16LittleEndian)
    }

    @Test("An older UTF-8 version stays UTF-8 under a working copy now saved as UTF-16")
    func utf8BlobUnderWideWorkingCopy() {
        let text = "SELECT id FROM customers;\n"

        #expect(FileTextLoader.decode(Data(text.utf8), declaredEncoding: .utf16LittleEndian) == text)
        #expect(FileTextLoader.unmarkedWideEncoding(of: Data(text.utf8)) == nil)
    }
}
