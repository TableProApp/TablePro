//
//  SQLExportEncodingDeclaration.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

internal struct SQLExportEncodingDeclaration: Equatable {
    static let empty = SQLExportEncodingDeclaration(prologue: "", epilogue: "")

    let prologue: String
    let epilogue: String

    static func forDialect(_ dialect: SqlDialect) -> SQLExportEncodingDeclaration {
        switch dialect {
        case .mysql:
            return mysql
        default:
            return .empty
        }
    }

    private static let mysql = SQLExportEncodingDeclaration(
        prologue: """
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
        /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
        /*!40101 SET NAMES utf8 */;
        /*!50503 SET NAMES utf8mb4 */;


        """,
        epilogue: """

        /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
        /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
        /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

        """
    )
}
