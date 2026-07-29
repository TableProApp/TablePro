import Foundation
import TableProPluginKit

public final class CSVInspectorPlugin: NSObject, TableProPlugin, DocumentInspectorPlugin {
    public static var pluginName: String { "CSV Inspector" }
    public static var pluginVersion: String { "1.0.0" }
    public static var pluginDescription: String { "View and edit CSV and TSV files natively." }
    public static var capabilities: [PluginCapability] { [.documentInspector] }
    public static var dependencies: [String] { [] }

    public static var inspectorId: String { "csv" }
    public static var displayName: String { "CSV Inspector" }
    public static var supportedUTIs: [String] {
        [
            "public.comma-separated-values-text",
            "public.tab-separated-values-text"
        ]
    }
    public static var supportedFileExtensions: [String] { ["csv", "tsv"] }
    public static var canEdit: Bool { true }
    public static var iconName: String { "tablecells" }
    public static var documentClass: AnyClass { CSVDocument.self }

    public override required init() {
        super.init()
    }
}
