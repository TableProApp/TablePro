import UniformTypeIdentifiers

enum ERDiagramExportFormat: CaseIterable, Identifiable {
    case png
    case svg
    case pdf
    case mermaid
    case graphviz

    var id: Self { self }

    var name: String {
        switch self {
        case .png: return "PNG"
        case .svg: return "SVG"
        case .pdf: return "PDF"
        case .mermaid: return "Mermaid"
        case .graphviz: return "Graphviz DOT"
        }
    }

    // Graphviz recommends `.gv`: `.dot` resolves to Word's template type.
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .svg: return "svg"
        case .pdf: return "pdf"
        case .mermaid: return "mmd"
        case .graphviz: return "gv"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .svg: return .svg
        case .pdf: return .pdf
        case .mermaid, .graphviz:
            return UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }
}
