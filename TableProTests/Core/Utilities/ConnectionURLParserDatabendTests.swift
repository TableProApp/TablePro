import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection URL Parser - Databend")
struct ConnectionURLParserDatabendTests {
    @Test("databend:// is Databend's HTTP DSN and stays unsupported")
    func databendSchemeUnsupported() {
        let result = ConnectionURLParser.parse("databend://root:pass@host:8000/default")
        guard case .failure(let error) = result else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .unsupportedScheme("databend"))
    }

    @Test("databend+ssh:// is not claimed either")
    func databendSshSchemeUnsupported() {
        let result = ConnectionURLParser.parse("databend+ssh://sshuser@sshhost:22/root:pass@dbhost/default")
        guard case .failure = result else {
            Issue.record("Expected failure"); return
        }
    }
}
