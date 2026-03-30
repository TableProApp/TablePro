//
//  CreateTableOptions.swift
//  TablePro
//
//  Table-level options for CREATE TABLE generation.
//

import Foundation

struct CreateTableOptions: Hashable {
    var engine: String = "InnoDB"
    var charset: String = "utf8mb4"
    var collation: String = "utf8mb4_unicode_ci"
    var ifNotExists: Bool = false

    static let engines = [
        "InnoDB", "MyISAM", "MEMORY", "CSV", "ARCHIVE",
        "BLACKHOLE", "MERGE", "FEDERATED", "NDB"
    ]

    static let charsets = [
        "utf8mb4", "utf8mb3", "utf8", "latin1", "ascii",
        "binary", "utf16", "utf32", "cp1251", "big5",
        "euckr", "gb2312", "gbk", "sjis"
    ]

    static let collations: [String: [String]] = [
        "utf8mb4": [
            "utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_bin",
            "utf8mb4_0900_ai_ci", "utf8mb4_unicode_520_ci"
        ],
        "utf8mb3": ["utf8mb3_unicode_ci", "utf8mb3_general_ci", "utf8mb3_bin"],
        "utf8": ["utf8_unicode_ci", "utf8_general_ci", "utf8_bin"],
        "latin1": ["latin1_swedish_ci", "latin1_general_ci", "latin1_bin"],
        "ascii": ["ascii_general_ci", "ascii_bin"],
        "binary": ["binary"],
        "utf16": ["utf16_unicode_ci", "utf16_general_ci", "utf16_bin"],
        "utf32": ["utf32_unicode_ci", "utf32_general_ci", "utf32_bin"],
        "cp1251": ["cp1251_general_ci", "cp1251_ukrainian_ci", "cp1251_bin"],
        "big5": ["big5_chinese_ci", "big5_bin"],
        "euckr": ["euckr_korean_ci", "euckr_bin"],
        "gb2312": ["gb2312_chinese_ci", "gb2312_bin"],
        "gbk": ["gbk_chinese_ci", "gbk_bin"],
        "sjis": ["sjis_japanese_ci", "sjis_bin"],
    ]
}
