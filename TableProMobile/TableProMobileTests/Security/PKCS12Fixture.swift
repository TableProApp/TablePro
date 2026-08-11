import Foundation

enum PKCS12Fixture {
    static let password = "tablepro"
    static let commonName = "TablePro Test Client"

    static var data: Data {
        guard let decoded = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) else {
            fatalError("PKCS12Fixture base64 is malformed")
        }
        return decoded
    }

    private static let base64 = """
        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
        BAhbCoOMA2JlPAICCAA=
        """
}
