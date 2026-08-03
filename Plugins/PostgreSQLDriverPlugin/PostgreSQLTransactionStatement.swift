import Foundation
import TableProPluginKit

internal func postgresBeginTransactionStatement(mode: PluginTransactionAccessMode) -> String {
    mode == .readWrite ? "BEGIN READ WRITE" : "BEGIN"
}
