import AppKit

final class AnnotationCanvasView: NSView {
    weak var state: AppState?
    private var currentAnnotation: Annotation?
    private var activeTextField: InlineTextField?
    private var activeTextPanel: InlineTextPanel?
    private var activeTextImagePoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        bounds.fill()

        guard let image = state?.baseImage else {
            return
        }

        let imageRect = fittedImageRect(for: image)
        image.draw(in: imageRect)

        let imageSize = image.pixelSize
        AnnotationRenderer.draw(annotations: state?.annotations ?? [], in: imageRect, imageSize: imageSize)
        if let currentAnnotation {
            AnnotationRenderer.draw(annotation: currentAnnotation, in: imageRect, imageSize: imageSize)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitInlineText()
        window?.makeFirstResponder(self)
        guard let state, let image = state.baseImage else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = imagePoint(from: point, image: image) else { return }

        if state.selectedTool == .text {
            beginInlineText(at: imagePoint, viewPoint: point)
            return
        }

        let annotation = Annotation(
            tool: state.selectedTool,
            start: imagePoint,
            end: imagePoint,
            points: state.selectedTool == .pen ? [imagePoint] : [],
            color: state.selectedColor,
            lineWidth: state.strokeWidth
        )
        currentAnnotation = annotation
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state, let image = state.baseImage, var annotation = currentAnnotation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = imagePoint(from: point, image: image) else { return }

        annotation.end = imagePoint
        if state.selectedTool == .pen {
            annotation.points.append(imagePoint)
        }
        currentAnnotation = annotation
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard let state, var annotation = currentAnnotation else { return }
        currentAnnotation = nil

        if annotation.tool != .pen {
            annotation.end = finalImagePoint(from: event) ?? annotation.end
        }

        if shouldCommit(annotation) {
            state.addAnnotation(annotation)
        }
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            currentAnnotation = nil
            setNeedsDisplay(bounds)
            state?.statusMessage = "Current annotation cancelled."
            return
        }
        super.keyDown(with: event)
    }

    private func beginInlineText(at imagePoint: CGPoint, viewPoint: CGPoint) {
        guard let state else { return }
        commitInlineText()

        let windowPoint = convert(viewPoint, to: nil)
        let screenPoint = window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        let panelFrame = NSRect(x: screenPoint.x, y: screenPoint.y - 34, width: 260, height: 34)
        let panel = InlineTextPanel(contentRect: panelFrame)
        let field = InlineTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 34))
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.textColor = state.selectedColor
        field.backgroundColor = .textBackgroundColor.withAlphaComponent(0.92)
        field.placeholderString = "Type label"
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.targetCanvas = self
        panel.contentView = field
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)

        activeTextField = field
        activeTextPanel = panel
        activeTextImagePoint = imagePoint
        state.statusMessage = "Type text, Enter to place, Esc to cancel."
    }

    func commitInlineText() {
        guard let field = activeTextField, let imagePoint = activeTextImagePoint, let state else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTextPanel?.orderOut(nil)
        activeTextPanel?.contentView = nil
        activeTextField = nil
        activeTextPanel = nil
        activeTextImagePoint = nil
        window?.makeFirstResponder(self)

        guard !text.isEmpty else {
            setNeedsDisplay(bounds)
            return
        }

        let annotation = Annotation(
            tool: .text,
            start: imagePoint,
            end: imagePoint,
            text: text,
            color: state.selectedColor,
            lineWidth: state.strokeWidth
        )
        state.addAnnotation(annotation)
        setNeedsDisplay(bounds)
    }

    func cancelInlineText() {
        activeTextPanel?.orderOut(nil)
        activeTextPanel?.contentView = nil
        activeTextField = nil
        activeTextPanel = nil
        activeTextImagePoint = nil
        window?.makeFirstResponder(self)
        state?.statusMessage = "Text cancelled."
        setNeedsDisplay(bounds)
    }

    private func shouldCommit(_ annotation: Annotation) -> Bool {
        if annotation.tool == .pen {
            return annotation.points.count > 1
        }
        let distance = hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y)
        return distance > 4
    }

    private func finalImagePoint(from event: NSEvent) -> CGPoint? {
        guard let image = state?.baseImage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return imagePoint(from: point, image: image)
    }

    private func imagePoint(from point: CGPoint, image: NSImage) -> CGPoint? {
        let rect = fittedImageRect(for: image)
        guard rect.contains(point) else { return nil }
        let imageSize = image.pixelSize
        return CGPoint(
            x: ((point.x - rect.minX) / rect.width) * imageSize.width,
            y: ((point.y - rect.minY) / rect.height) * imageSize.height
        )
    }

    private func fittedImageRect(for image: NSImage) -> NSRect {
        let imageSize = image.pixelSize
        let available = bounds.insetBy(dx: 10, dy: 10)
        guard imageSize.width > 0, imageSize.height > 0 else { return available }

        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }

}

final class InlineTextPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class InlineTextField: NSTextField, NSTextFieldDelegate {
    weak var targetCanvas: AnnotationCanvasView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            targetCanvas?.commitInlineText()
            return
        }

        if event.keyCode == 53 {
            targetCanvas?.cancelInlineText()
            return
        }

        super.keyDown(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            targetCanvas?.commitInlineText()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            targetCanvas?.cancelInlineText()
            return true
        }

        return false
    }
}

private extension NSImage {
    var pixelSize: NSSize {
        if let rep = representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}
