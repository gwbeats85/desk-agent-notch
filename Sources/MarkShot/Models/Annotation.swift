import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case pointer
    case arrow
    case rectangle
    case ellipse
    case pen
    case text
    case redact
    case headerBlock
    case cardBlock
    case tagPill
    case buttonBlock
    case inputBlock

    var id: String { rawValue }

    static let markupTools: [AnnotationTool] = [.pointer, .arrow, .rectangle, .ellipse, .pen, .text, .redact]
    static let boardAssetTools: [AnnotationTool] = [.headerBlock, .cardBlock, .tagPill, .buttonBlock, .inputBlock]

    var label: String {
        switch self {
        case .pointer: "Pointer"
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .ellipse: "Circle"
        case .pen: "Pen"
        case .text: "Text"
        case .redact: "Redact"
        case .headerBlock: "Header"
        case .cardBlock: "Card"
        case .tagPill: "Tag"
        case .buttonBlock: "Button"
        case .inputBlock: "Input"
        }
    }

    var symbolName: String {
        switch self {
        case .pointer: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .redact: "eye.slash"
        case .headerBlock: "rectangle.topthird.inset.filled"
        case .cardBlock: "rectangle.inset.filled"
        case .tagPill: "tag"
        case .buttonBlock: "capsule"
        case .inputBlock: "textfield"
        }
    }
}

struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var color: NSColor
    var lineWidth: CGFloat
}
