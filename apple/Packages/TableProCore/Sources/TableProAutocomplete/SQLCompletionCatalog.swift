import Foundation

// Each app answers from its own schema cache, so both rank through one provider.
public protocol SQLCompletionCatalog: Sendable {
    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) async -> String?
    func columnCompletionItems(for tableName: String, schema: String?) async -> [SQLCompletionItem]
    func tableCompletionItems() async -> [SQLCompletionItem]
    func tableCompletionItems(inSchema schema: String) async -> [SQLCompletionItem]
    func schemaCompletionItems() async -> [SQLCompletionItem]
    func namespaceCompletionItems() async -> [SQLCompletionItem]
    func isKnownSchema(_ name: String) async -> Bool
    func isKnownDatabase(_ name: String) async -> Bool
    func allowedValues(forColumn column: String, in references: [TableReference]) async -> [String]
    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem]
    func allColumnsFromCachedTables() async -> [SQLCompletionItem]
}
