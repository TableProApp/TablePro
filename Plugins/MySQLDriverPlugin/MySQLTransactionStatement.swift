import Foundation
import TableProPluginKit

internal func mysqlBeginTransactionStatement(mode: PluginTransactionAccessMode) -> String {
    mode == .readWrite ? "START TRANSACTION READ WRITE" : "START TRANSACTION"
}
