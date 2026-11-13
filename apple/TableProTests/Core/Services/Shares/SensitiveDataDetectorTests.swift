//
//  SensitiveDataDetectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The rows of DETECTOR-FIXTURES.md (core/crates/core/src/masking/detect/fixtures.rs), so the core and this app agree.
struct SensitiveDataDetectorTests {
    // Built at run time so no literal in this file reads as a live credential to a scanner.
    static let fakeAWS = "AKIA" + "IOSFODNN7EXAMPLE"
    static let otherAWS = "AKIA" + "IOSFODNN7EXAMPLF"
    static let fakeGitHub = "ghp_" + "0123456789abcdefghijABCDEFGHIJ012345"
    static let fakeGoogle = "AIza" + "SyA1234567890abcdefghijklmnopqrstuv"
    static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123"

    static let nameRows: [(String, SensitiveNameKind?)] = [
        ("email", .email), ("E-Mail", .email), ("e_mail", .email), ("mail", .email),
        ("work_mail", .email), ("ma_il", nil), ("email_address", .email), ("phone", .phone), ("mobilePhone", .phone),
        ("mobile", .phone), ("tel_no", .phone), ("hotel", nil), ("fax", .phone), ("msisdn", .phone),
        ("password_hash", .secret), ("passwords", nil), ("stripe_api_key", .secret), ("apiKey", .secret),
        ("API-KEY", .secret), ("aws_access_key", .secret), ("PrivateKey", .secret), ("credential", .secret),
        ("credentials", nil), ("refresh_token", .secret), ("ssn", .nationalID), ("customerSSN", .nationalID),
        ("ssn4", .nationalID), ("classname", nil), ("class_name", nil), ("social_security_number", .nationalID),
        ("national_id", .nationalID), ("tax_id", .nationalID), ("tin", .nationalID),
        ("credit_card_number", .cardOrAccount), ("CardNumber", .cardOrAccount), ("pan", .cardOrAccount),
        ("company", nil), ("iban", .cardOrAccount), ("routing_number", .cardOrAccount), ("street_address", .address),
        ("street", .address), ("Address2Line", .address), ("zip", .address), ("zipcode", .address),
        ("zip_code", .address), ("postal_code", .address), ("dob", .birthDate), ("date_of_birth", .birthDate),
        ("birthday", .birthDate), ("ip", .ipAddress), ("ip_address", .ipAddress), ("IPAddress", .ipAddress),
        ("ipv4", .ipAddress), ("client_ipv6", .ipAddress), ("ipv", nil), ("user_first_name", .personName),
        ("lastName", .personName), ("surname", .personName), ("given_name", .personName),
        ("home_phone_address", .phone), ("id", nil), ("", nil)
    ]

    static let valueRows: [(String, [SensitiveValueKind])] = [
        ("4111 1111 1111 1111", [.card]), ("4111-1111-1111-1111", [.card]), ("4111111111111111", [.card]),
        ("4222222222222", [.card]), ("4222 2222 22222", [.card, .phone]), ("4111111111111112", []), ("411111111111", []),
        ("4111.1111.1111.1111", []), (" 4111111111111111", [.card]), ("GB82 WEST 1234 5698 7654 32", [.iban]),
        ("GB82WEST12345698765432", [.iban]), ("DE89 3704 0044 0532 0130 00", [.iban]),
        ("GB82 WEST 1234 5698 7654 33", []), ("gb82west12345698765432", []), ("GB82\tWEST12345698765432", []),
        (SensitiveDataDetectorTests.jwt, [.jsonWebToken]), (" eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc", []),
        (SensitiveDataDetectorTests.fakeAWS, [.apiKey]), ("key=\(SensitiveDataDetectorTests.fakeAWS);", [.apiKey]),
        (SensitiveDataDetectorTests.fakeGitHub, [.apiKey]), ("xoxb-123", [.apiKey]), ("sk_live_abc", [.apiKey]),
        (SensitiveDataDetectorTests.fakeGoogle, [.apiKey]), ("sk_test_abc", []), ("ann@example.com", [.email]),
        ("émile@exämple.fr", [.email]), ("a@b@c.com", []), ("ann@localhost", []), ("ann @example.com", []),
        ("ann@example.com ", []), ("ann\u{a0}x@example.com", []), ("+1 555 0100", [.phone]), ("(555) 010-0100", [.phone]),
        ("555.010.0100", [.phone]), ("+15550100", [.phone]), ("1.234.567", [.phone]), ("5550100", []), ("+123456", []),
        ("+1234567890123456", []), ("555-0100 ext 2", []), ("2024-01-02", []), ("2024-01-0212345", []),
        ("1234567.89", []), ("-1234567.89", []), ("12:30:45", []), ("192.168.100.200", [.ipAddress]),
        ("192.168.1.1", [.ipAddress]), ("0.0.0.0", [.ipAddress]), ("192.168.01.1", [.phone]), ("256.1.1.1", []),
        ("256.10.10.10", [.phone]), ("1.2.3", []), ("1.1.1.1 ", []), ("::1", [.ipAddress]), ("2001:db8::1", [.ipAddress]),
        ("1:2:3:4:5:6:7:8", [.ipAddress]), ("::ffff:192.168.1.1", [.ipAddress]), ("fe80::1%eth0", []), ("[::1]", []),
        ("2001:db8::1::2", []), ("12345::1", []), ("", [])
    ]

    static let columnRows: [(String, [PluginCellValue], SensitiveValueKind?)] = [
        ("text", [.text("ann@example.com"), .text("bob@example.com"), .text("n/a"), .text("x")], .email),
        ("text", [.text("ann@example.com"), .text("x"), .text("y")], nil),
        ("text", [.text("ann@example.com"), .null, .null], .email),
        ("text", [.text("ann@example.com"), .text(""), .text("")], nil),
        ("text", [.text("ann@example.com"), .bytes(Data([1])), .bytes(Data([2]))], nil),
        ("text", [.text("x"), .text("y"), .text("4111 1111 1111 1111")], .card),
        ("text", [.text("ann@example.com"), .text(SensitiveDataDetectorTests.jwt)], .jsonWebToken),
        ("text", [.text("192.168.1.1"), .text("10.0.0.1")], .ipAddress),
        ("varchar(64)", [.text("+1 555 0100"), .text("x")], .phone),
        ("", [.text("ann@example.com")], .email),
        ("Nullable(String)", [.text("ann@example.com")], .email),
        ("bigint", [.text("4111111111111111")], nil),
        ("uuid", [.text("ann@example.com")], nil),
        ("Nullable(UInt64)", [.text("4111111111111111")], nil),
        ("timestamp with time zone", [.text("2024-01-02 10:00:00+00")], nil),
        ("text", [.null, .null], nil),
        ("text", [], nil)
    ]

    static let sqlRows: [(String, [String])] = [
        ("SELECT * FROM users WHERE email = 'ann@example.com'", ["email:1"]),
        ("SELECT \"ann@example.com\" FROM t", []),
        ("WHERE note = 'call +1 555 0100'", []),
        ("WHERE card = '4111-1111-1111-1111'", ["card:1"]),
        ("WHERE iban = 'GB82 WEST 1234 5698 7654 32'", ["iban:1"]),
        ("SET token = '\(SensitiveDataDetectorTests.jwt)'", ["jwt:1"]),
        ("WHERE k = 'id \(SensitiveDataDetectorTests.fakeAWS)'", ["api_key:1"]),
        ("SELECT 'o''brien@example.com'", ["email:1"]),
        ("WHERE ip = '192.168.1.1'", []),
        ("WHERE e = 'ann@example.com", []),
        ("-- don't\nWHERE e = 'ann@example.com'", ["email:2"]),
        ("SELECT /* it's */ 'ann@example.com'", ["email:1"]),
        ("SELECT 1 -- 'ann@example.com'", []),
        ("SELECT 1 /* 'ann@example.com' */", []),
        ("/* 'ann@example.com'", []),
        ("-- it's\r'ann@example.com'", ["email:2"]),
        ("SELECT 'a--b@example.com'", ["email:1"]),
        ("SELECT \"x--y\", 'ann@example.com'", ["email:1"]),
        ("SELECT 1 - -1, 'ann@example.com'", ["email:1"]),
        ("WHERE e = 'a@b.co' AND f = 'c@d.co'\nOR p = '(555) 010-0100'", ["email:1", "phone:2"]),
        ("SELECT 1;\r\n\r\nSELECT '+1 555 0100'", ["phone:3"]),
        ("SELECT 1", [])
    ]

    // MARK: - Column names

    @Test("Column names, fixture table", arguments: SensitiveDataDetectorTests.nameRows)
    func columnNames(name: String, kind: SensitiveNameKind?) {
        #expect(SensitiveDataDetector.nameKind(name) == kind)
    }

    @Test("Each name kind suggests its style")
    func nameStyles() {
        #expect(SensitiveNameKind.allCases.map(\.style) == [.email, .lastFour, .full, .lastFour, .lastFour, .full, .full, .hash, .full])
    }

    @Test("Words are lower-cased and split only where the rules say")
    func wordSplitting() {
        #expect(SensitiveDataDetector.words(in: "userFirstName2fa") == ["user", "first", "name", "2", "fa"])
        #expect(SensitiveDataDetector.words(in: "Address2Line") == ["address", "2", "line"])
        #expect(SensitiveDataDetector.words(in: "IPAddress") == ["ipaddress"])
        #expect(SensitiveDataDetector.words(in: "e.mail  x") == ["e", "mail", "x"])
        #expect(SensitiveDataDetector.words(in: "e#mail") == ["e#mail"])
        #expect(SensitiveDataDetector.words(in: "__").isEmpty)
    }

    // MARK: - Column types

    @Test("Text-like types, including unknown ones", arguments: [
        nil, "", "text", "varchar(255)", "jsonb", "String", "interval_text", "geometry", "inet",
        "LowCardinality(Nullable(String))", "_int8"
    ] as [String?])
    func textLikeTypes(type: String?) {
        #expect(SensitiveDataDetector.isTextLike(type))
    }

    @Test("Number, date, boolean and UUID types are not text-like", arguments: [
        "int", "bigint unsigned", "UInt64", "Nullable(Int32)", "double precision", "timestamp with time zone", "Date32",
        "DateTime64(3)", "numeric(10,2)", "uniqueidentifier", "BOOLEAN", "tinyint(1)", "uuid", "money", "year"
    ])
    func nonTextTypes(type: String) {
        #expect(!SensitiveDataDetector.isTextLike(type))
    }

    // MARK: - Values

    @Test("Values, fixture table: each kind tested alone", arguments: SensitiveDataDetectorTests.valueRows)
    func values(value: String, kinds: [SensitiveValueKind]) {
        #expect(SensitiveValueKind.allCases.filter { SensitiveDataDetector.matches($0, value) } == kinds)
    }

    @Test("Email white space is Unicode White_Space, which ICU's \\s leaves partly out")
    func emailWhiteSpace() {
        #expect(!SensitiveDataDetector.matches(.email, "ann@example.com\u{0B}"))
        #expect(!SensitiveDataDetector.matches(.email, "ann@example.com\u{85}"))
        #expect(!SensitiveDataDetector.matches(.email, "ann@example.com\n"))
    }

    @Test("An email check over a long domain that never matches stays linear")
    func emailStaysLinear() {
        let dots = String(repeating: ".", count: 100_000)
        let started = ContinuousClock.now
        #expect(!SensitiveDataDetector.matches(.email, "a@" + dots + " "))
        #expect(SensitiveDataDetector.matches(.email, "a@b" + dots + "c"))
        // Dots are domain characters too, so this one matches the anchored pattern.
        #expect(SensitiveDataDetector.matches(.email, "a@" + dots))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("IP addresses are what Rust's std::net parser accepts", arguments: [
        ("255.255.255.255", true), ("01.2.3.4", false), ("1.2.3.4.5", false), ("::", true),
        ("2001:0DB8:0000:0000:0000:0000:0000:0001", true), ("::1.2.3.4", true), ("1:2:3:4:5:6:1.2.3.4", true),
        ("1:2:3:4:5:6:7::", true), ("::1:2:3:4:5:6:7", true), ("1:2:3:4:5:6:7:8:9", false),
        ("1:2:3:4:5:6:7:1.2.3.4", false), ("1.2.3.4::", false), ("::ffff:01.2.3.4", false), ("1:2:3:4:5:6:7:8::", false)
    ])
    func ipAddressEdges(value: String, matches: Bool) {
        #expect(SensitiveDataDetector.matches(.ipAddress, value) == matches)
    }

    // MARK: - A column's values

    @Test("Columns, fixture table: thresholds and text-like types", arguments: SensitiveDataDetectorTests.columnRows)
    func columns(type: String, values: [PluginCellValue], flagged: SensitiveValueKind?) throws {
        let source = ShareResultSource(
            columns: ["c"], columnTypes: [.text(rawType: type)], rows: values.map { [$0] }, totalRowCount: values.count, sql: ""
        )
        let detections = try #require(SensitiveDataDetector.detections(in: source, maxRows: 100))
        #expect(detections[0] == flagged.map(SensitiveDetection.values))
    }

    // MARK: - A result

    @Test("A name beats the values, and a column the rules mask gets nothing")
    func resultDetections() throws {
        let source = ShareResultSource(
            columns: ["phone", "notes", "email", "id"],
            columnTypes: [.text(rawType: "text"), .text(rawType: "text"), .text(rawType: "text"), .integer(rawType: "int")],
            rows: [[.text("ann@example.com"), .text("4111 1111 1111 1111"), .text("x"), .text("1")]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [2: .full])
        )
        let detections = try #require(SensitiveDataDetector.detections(in: source, maxRows: 10))
        #expect(detections == [0: .name(.phone), 1: .values(.card)])
    }

    @Test("Only the rows that will be shared are read")
    func detectionsReadOnlyMaxRows() throws {
        let source = ShareResultSource(
            columns: ["notes"], columnTypes: [.text(rawType: "text")], rows: [[.text("x")], [.text("4111111111111111")]],
            totalRowCount: 2, sql: ""
        )
        #expect(try #require(SensitiveDataDetector.detections(in: source, maxRows: 1)).isEmpty)
        #expect(try #require(SensitiveDataDetector.detections(in: source, maxRows: 2)) == [0: .values(.card)])
    }

    // MARK: - SQL

    @Test("SQL personal data, fixture table", arguments: SensitiveDataDetectorTests.sqlRows)
    func sqlPersonalData(sql: String, hits: [String]) {
        #expect(SensitiveDataDetector.personalDataHits(inSQL: sql).map { "\($0.kind.code):\($0.line)" } == hits)
    }

    @Test("Literals read '' as a quote, skip double-quoted names and comments, and drop one left open")
    func quotedLiterals() {
        let literals = SensitiveDataDetector.quotedLiterals(in: "SELECT 'it''s', \"a'b\", 'x' FROM t WHERE c = 'open")
        #expect(literals.map(\.text) == ["it's", "x"])
        #expect(SensitiveDataDetector.quotedLiterals(in: "''").map(\.text) == [""])
        #expect(SensitiveDataDetector.quotedLiterals(in: "'abc''").isEmpty)
        #expect(SensitiveDataDetector.quotedLiterals(in: "SELECT 1\r\n'a'\r'b'\n'c\nd'").map(\.line) == [2, 3, 4])
        #expect(SensitiveDataDetector.quotedLiterals(in: "-- it's\r\n'a' /* 'b' */ \"c'd\" 'e' /* open 'f'").map(\.text) == ["a", "e"])
        #expect(SensitiveDataDetector.quotedLiterals(in: "'--', '/*', 'x'").map(\.text) == ["--", "/*", "x"])
        // core sql.rs, comments_outside_a_literal_are_skipped.
        let commented = SensitiveDataDetector.quotedLiterals(in: "-- don't\nSELECT /* it's */ 'a', '-- b /* c */' -- 'd'\r'e'")
        #expect(commented.map(\.text) == ["a", "-- b /* c */", "e"])
        #expect(commented.map(\.line) == [2, 2, 3])
        #expect(SensitiveDataDetector.quotedLiterals(in: "/* 'open").isEmpty)
    }

    @Test("The kinds for the Hide SQL notice come in table order, each once")
    func personalDataKinds() {
        let sql = "WHERE e = 'ann@example.com'\nAND p = '+1 555 0100' AND c = '4111111111111111' AND f = 'bob@example.com'"
        #expect(SensitiveDataDetector.personalData(inSQL: sql) == [.card, .email, .phone])
    }
}

private extension SensitiveValueKind {
    var code: String {
        switch self {
        case .card: "card"
        case .iban: "iban"
        case .jsonWebToken: "jwt"
        case .apiKey: "api_key"
        case .email: "email"
        case .phone: "phone"
        case .ipAddress: "ip"
        }
    }
}
