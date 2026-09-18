import Foundation
import TableProPluginKit

nonisolated internal func postgresBeginTransactionStatement(mode: PluginTransactionAccessMode) -> String {
    mode == .readWrite ? "BEGIN READ WRITE" : "BEGIN"
}
