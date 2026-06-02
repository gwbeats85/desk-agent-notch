import SwiftUI

struct AnnotationCanvasRepresentable: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        nsView.state = state
        nsView.needsDisplay = true
    }
}
