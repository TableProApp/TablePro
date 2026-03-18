import Foundation
import Testing
@testable import TablePro

@Suite("URL Sanitization")
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

    @Test("Non-database file URL returns original string")
    func fileUrl() {
        let url = URL(string: "file:///Users/test/documents/data.sql")!
        let result = url.sanitizedForLogging
        #expect(result == "file:///Users/test/documents/data.sql")
    }
}
