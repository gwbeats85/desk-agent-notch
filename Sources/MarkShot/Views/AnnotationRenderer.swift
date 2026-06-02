import AppKit

enum AnnotationRenderer {
    static func draw(annotations: [Annotation], in rect: NSRect, imageSize: NSSize) {
        for annotation in annotations {
            draw(annotation: annotation, in: rect, imageSize: imageSize)
        }
    }

    static func draw(annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        switch annotation.tool {
        case .pointer:
            break
        case .arrow:
            drawArrow(annotation, in: rect, imageSize: imageSize)
        case .rectangle:
            drawRectangle(annotation, in: rect, imageSize: imageSize)
        case .ellipse:
            drawEllipse(annotation, in: rect, imageSize: imageSize)
        case .pen:
            drawPen(annotation, in: rect, imageSize: imageSize)
        case .text:
            drawText(annotation, in: rect, imageSize: imageSize)
        case .redact:
            drawRedact(annotation, in: rect, imageSize: imageSize)
        case .headerBlock, .cardBlock, .tagPill, .buttonBlock, .inputBlock:
            drawBoardAsset(annotation, in: rect, imageSize: imageSize)
        }
    }

    private static func point(_ point: CGPoint, in rect: NSRect, imageSize: NSSize) -> CGPoint {
        CGPoint(
            x: rect.minX + (point.x / imageSize.width) * rect.width,
            y: rect.minY + (point.y / imageSize.height) * rect.height
        )
    }

    private static func lineWidth(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) -> CGFloat {
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        return max(1.5, annotation.lineWidth * scale)
    }

    private static func rectFor(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) -> NSRect {
        let start = point(annotation.start, in: rect, imageSize: imageSize)
        let end = point(annotation.end, in: rect, imageSize: imageSize)
        return NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }

    private static func drawArrow(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let start = point(annotation.start, in: rect, imageSize: imageSize)
        let end = point(annotation.end, in: rect, imageSize: imageSize)
        let width = lineWidth(annotation, in: rect, imageSize: imageSize)

        annotation.color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(16, width * 5)
        let headAngle: CGFloat = .pi / 7

        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        let head = NSBezierPath()
        head.lineWidth = width
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.move(to: left)
        head.line(to: end)
        head.line(to: right)
        head.stroke()
    }

    private static func drawRectangle(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let box = rectFor(annotation, in: rect, imageSize: imageSize)
        let width = lineWidth(annotation, in: rect, imageSize: imageSize)
        annotation.color.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: box).fill()
        annotation.color.setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = width
        path.stroke()
    }

    private static func drawEllipse(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let box = rectFor(annotation, in: rect, imageSize: imageSize)
        let width = lineWidth(annotation, in: rect, imageSize: imageSize)
        annotation.color.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: box).fill()
        annotation.color.setStroke()
        let path = NSBezierPath(ovalIn: box)
        path.lineWidth = width
        path.stroke()
    }

    private static func drawPen(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        guard let first = annotation.points.first else { return }
        let width = lineWidth(annotation, in: rect, imageSize: imageSize)
        annotation.color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(first, in: rect, imageSize: imageSize))
        for pointValue in annotation.points.dropFirst() {
            path.line(to: point(pointValue, in: rect, imageSize: imageSize))
        }
        path.stroke()
    }

    private static func drawText(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let origin = point(annotation.start, in: rect, imageSize: imageSize)
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let fontSize = max(15, 28 * scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: annotation.color,
            .backgroundColor: NSColor.black.withAlphaComponent(annotation.color == .white ? 0.55 : 0)
        ]
        let text = annotation.text as NSString
        text.draw(at: origin, withAttributes: attributes)
    }

    private static func drawRedact(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let box = rectFor(annotation, in: rect, imageSize: imageSize)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(rect: box).fill()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = max(1, lineWidth(annotation, in: rect, imageSize: imageSize) * 0.5)
        path.stroke()
    }

    private static func drawBoardAsset(_ annotation: Annotation, in rect: NSRect, imageSize: NSSize) {
        let box = rectFor(annotation, in: rect, imageSize: imageSize)
        guard box.width >= 28, box.height >= 20 else { return }

        switch annotation.tool {
        case .headerBlock:
            drawHeaderBlock(in: box, annotation: annotation)
        case .cardBlock:
            drawCardBlock(in: box, annotation: annotation)
        case .tagPill:
            drawPill(in: box, label: "TAG", annotation: annotation)
        case .buttonBlock:
            drawButton(in: box, label: "BUTTON", annotation: annotation)
        case .inputBlock:
            drawInput(in: box, annotation: annotation)
        default:
            break
        }
    }

    private static func drawHeaderBlock(in box: NSRect, annotation: Annotation) {
        guard box.width >= 28, box.height >= 20 else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.92).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.82).setFill()
        let headerHeight = max(12, min(46, box.height * 0.42))
        NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.maxY - headerHeight, width: box.width, height: headerHeight), xRadius: 10, yRadius: 10).fill()
        drawGuideLine(in: safeInset(box, dx: 18, dy: min(18, box.height * 0.22)), yOffset: 0.28, color: annotation.color)
        strokeAssetBox(path)
    }

    private static func drawCardBlock(in box: NSRect, annotation: Annotation) {
        guard box.width >= 28, box.height >= 20 else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(0.9).setFill()
        path.fill()
        let guideBox = safeInset(box, dx: 18, dy: min(18, box.height * 0.22))
        drawGuideLine(in: guideBox, yOffset: 0.72, color: annotation.color)
        drawGuideLine(in: guideBox, yOffset: 0.46, color: .black.withAlphaComponent(0.28))
        drawGuideLine(in: guideBox, yOffset: 0.26, color: .black.withAlphaComponent(0.2))
        strokeAssetBox(path)
    }

    private static func drawPill(in box: NSRect, label: String, annotation: Annotation) {
        let path = NSBezierPath(roundedRect: box, xRadius: min(box.height / 2, 18), yRadius: min(box.height / 2, 18))
        annotation.color.withAlphaComponent(0.14).setFill()
        path.fill()
        annotation.color.setStroke()
        path.lineWidth = 2
        path.stroke()
        drawAssetLabel(label, in: box, color: annotation.color)
    }

    private static func drawButton(in box: NSRect, label: String, annotation: Annotation) {
        let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        annotation.color.setFill()
        path.fill()
        drawAssetLabel(label, in: box, color: .white)
    }

    private static func drawInput(in box: NSRect, annotation: Annotation) {
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.88).setFill()
        path.fill()
        strokeAssetBox(path)
        drawAssetLabel("INPUT", in: safeInset(box, dx: 12, dy: 0), color: .black.withAlphaComponent(0.45), alignment: .left)
    }

    private static func drawGuideLine(in box: NSRect, yOffset: CGFloat, color: NSColor) {
        guard box.width > 2, box.height >= 0, box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite else { return }
        color.setStroke()
        let y = box.minY + box.height * yOffset
        guard y.isFinite else { return }
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: box.minX, y: y))
        path.line(to: CGPoint(x: box.maxX, y: y))
        path.stroke()
    }

    private static func drawAssetLabel(_ label: String, in box: NSRect, color: NSColor, alignment: NSTextAlignment = .center) {
        guard box.width > 4, box.height > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(16, box.height * 0.34)), weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let labelRect = box.insetBy(dx: 8, dy: max(2, (box.height - 18) / 2))
        guard labelRect.width > 2, labelRect.height > 2 else { return }
        (label as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    private static func safeInset(_ box: NSRect, dx: CGFloat, dy: CGFloat) -> NSRect {
        let safeDX = min(max(0, dx), max(0, (box.width - 4) / 2))
        let safeDY = min(max(0, dy), max(0, (box.height - 4) / 2))
        return box.insetBy(dx: safeDX, dy: safeDY)
    }

    private static func strokeAssetBox(_ path: NSBezierPath) {
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
