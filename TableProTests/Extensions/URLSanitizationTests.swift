import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct URLSanitizationTests {
    @Test("URL with password replaces password with ***")
    func urlWithPassword() {
        let url = URL(string: "mysql://admin:secret123@localhost:3306/mydb")!
        let result = url.sanitizedForLogging
        #expect(result == "mysql://admin:***@localhost:3306/mydb")
        #expect(!result.contains("secret123"))
    }

    @Test("URL without password returns original string unchanged")
    func urlWithoutPassword() {
        let url = URL(string: "mysql://localhost:3306/mydb")!
        let result = url.sanitizedForLogging
        #expect(result == "mysql://localhost:3306/mydb")
    }

    @Test("URL with only username and no password returns original string unchanged")
    func urlWithOnlyUsername() {
        let url = URL(string: "mysql://admin@localhost:3306/mydb")!
        let result = url.sanitizedForLogging
        #expect(result == "mysql://admin@localhost:3306/mydb")
    }

    @Test("URL with special characters in password is still sanitized")
    func urlWithSpecialCharactersInPassword() {
        let url = URL(string: "postgresql://user:p%40ss%23word%21@db.example.com:5432/prod")!
        let result = url.sanitizedForLogging
        #expect(!result.contains("p%40ss%23word%21"))
        #expect(result.contains("***"))
    }

    @Test("URL with empty password replaces password with ***")
    func urlWithEmptyPassword() {
        let url = URL(string: "mysql://user:@localhost:3306/mydb")!
        let result = url.sanitizedForLogging
        #expect(result.contains("***"))
    }

    @Test("A refused pairing link logs its parameter names, never their values")
    func pairingLinkValuesAreRedacted() throws {
        let url = try #require(URL(string:
            "tablepro://integrations/pair?client=Raycast&state=s3cr3t&response_mode=json&redirect=http%3A%2F%2F127.0.0.1%2Fcb&flag"
        ))
        let result = url.queryValuesRedactedForLogging
        #expect(result == "tablepro://integrations/pair?client=***&state=***&response_mode=***&redirect=***&flag")
    }

    @Test("Redacting query values still hides a password")
    func redactedQueryKeepsPasswordHidden() throws {
        let url = try #require(URL(string: "mysql://admin:secret@localhost:3306/db?sslmode=require#frag"))
        #expect(url.queryValuesRedactedForLogging == "mysql://admin:***@localhost:3306/db?sslmode=***")
    }

    @Test("Non-database file URL returns original string")
    func fileUrl() {
        let url = URL(string: "file:///Users/test/documents/data.sql")!
        let result = url.sanitizedForLogging
        #expect(result == "file:///Users/test/documents/data.sql")
    }
}
