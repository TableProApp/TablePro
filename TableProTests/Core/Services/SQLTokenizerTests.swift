//
//  SQLTokenizerTests.swift
//  TableProTests
//
//  Tests for SQLTokenizer — character-by-character SQL lexer.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLTokenizer")
struct SQLTokenizerTests {
    let tokenizer = SQLTokenizer()

    // MARK: - Keywords

    @Test("Recognizes standard SQL keywords")
    func standardKeywords() {
        let tokens = tokenizer.tokenize("SELECT FROM WHERE")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.count == 3)
        #expect(nonWS.allSatisfy { $0.type == .keyword })
    }

    @Test("Keywords are case-insensitive")
    func keywordCaseInsensitive() {
        let tokens = tokenizer.tokenize("select FROM Where")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.allSatisfy { $0.type == .keyword })
    }

    // MARK: - Identifiers

    @Test("Recognizes identifiers")
    func identifiers() {
        let tokens = tokenizer.tokenize("users my_table col1")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.count == 3)
        #expect(nonWS.allSatisfy { $0.type == .identifier })
    }

    @Test("Backtick-quoted identifiers")
    func backtickIdentifiers() {
        let tokens = tokenizer.tokenize("`my table`")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .identifier)
        #expect(tokens[0].value == "`my table`")
    }

    // MARK: - Strings

    @Test("Single-quoted string")
    func singleQuotedString() {
        let tokens = tokenizer.tokenize("'hello world'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'hello world'")
    }

    @Test("String with escaped quote")
    func stringWithEscapedQuote() {
        let tokens = tokenizer.tokenize("'it''s'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'it''s'")
    }

    @Test("String with backslash escape")
    func stringWithBackslashEscape() {
        let tokens = tokenizer.tokenize("'it\\'s'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
    }

    // MARK: - Numbers

    @Test("Integer")
    func integer() {
        let tokens = tokenizer.tokenize("42")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .number)
        #expect(tokens[0].value == "42")
    }

    @Test("Decimal number")
    func decimal() {
        let tokens = tokenizer.tokenize("3.14")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .number)
    }

    // MARK: - Comments

    @Test("Line comment")
    func lineComment() {
        let tokens = tokenizer.tokenize("-- this is a comment\nSELECT 1")
        let comments = tokens.filter { $0.type == .comment }
        #expect(comments.count == 1)
        #expect(comments[0].value == "-- this is a comment")
    }

    @Test("Block comment")
    func blockComment() {
        let tokens = tokenizer.tokenize("/* block */ SELECT 1")
        let comments = tokens.filter { $0.type == .comment }
        #expect(comments.count == 1)
        #expect(comments[0].value == "/* block */")
    }

    // MARK: - Operators

    @Test("Multi-character operators")
    func multiCharOperators() {
        let tokens = tokenizer.tokenize(">= <= <> !=")
        let ops = tokens.filter { $0.type == .operator }
        #expect(ops.count == 4)
        #expect(ops.map(\.value) == [">=", "<=", "<>", "!="])
    }

    // MARK: - Punctuation

    @Test("Punctuation tokens")
    func punctuation() {
        let tokens = tokenizer.tokenize("(a, b)")
        let puncts = tokens.filter { $0.type == .punctuation }
        #expect(puncts.map(\.value) == ["(", ",", ")"])
    }

    @Test("Semicolons")
    func semicolons() {
        let tokens = tokenizer.tokenize("SELECT 1; SELECT 2;")
        let semis = tokens.filter { $0.type == .punctuation && $0.value == ";" }
        #expect(semis.count == 2)
    }

    // MARK: - Placeholders

    @Test("Question mark placeholder")
    func questionMarkPlaceholder() {
        let tokens = tokenizer.tokenize("WHERE id = ?")
        let placeholders = tokens.filter { $0.type == .placeholder }
        #expect(placeholders.count == 1)
        #expect(placeholders[0].value == "?")
    }

    @Test("Named placeholders")
    func namedPlaceholders() {
        let tokens = tokenizer.tokenize("$1 :name @var")
        let placeholders = tokens.filter { $0.type == .placeholder }
        #expect(placeholders.count == 3)
        #expect(placeholders.map(\.value) == ["$1", ":name", "@var"])
    }

    // MARK: - Mixed Input

    @Test("Full SELECT statement tokens")
    func fullSelectStatement() {
        let tokens = tokenizer.tokenize("SELECT id, name FROM users WHERE active = true")
        let nonWS = tokens.filter { $0.type != .whitespace }
        // SELECT id , name FROM users WHERE active = true
        #expect(nonWS.count == 10)
        #expect(nonWS[0] == SQLToken(type: .keyword, value: "SELECT"))
        #expect(nonWS[1] == SQLToken(type: .identifier, value: "id"))
        #expect(nonWS[2] == SQLToken(type: .punctuation, value: ","))
        #expect(nonWS[3] == SQLToken(type: .identifier, value: "name"))
        #expect(nonWS[4] == SQLToken(type: .keyword, value: "FROM"))
        #expect(nonWS[5] == SQLToken(type: .identifier, value: "users"))
        #expect(nonWS[6] == SQLToken(type: .keyword, value: "WHERE"))
        #expect(nonWS[7] == SQLToken(type: .identifier, value: "active"))
        #expect(nonWS[8] == SQLToken(type: .operator, value: "="))
        #expect(nonWS[9] == SQLToken(type: .keyword, value: "true"))
    }

    @Test("Preserves original token values")
    func preservesOriginalValues() {
        let tokens = tokenizer.tokenize("select 'Hello World' from users")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS[0].value == "select") // preserves original case
        #expect(nonWS[1].value == "'Hello World'")
    }
}
