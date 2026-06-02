import AppKit

enum SmokeTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let inputIndex = arguments.firstIndex(of: "--smoke-render") else {
            return false
        }

        let outputIndex = arguments.firstIndex(of: "--smoke-output")
        guard arguments.indices.contains(inputIndex + 1),
              let outputIndex,
              arguments.indices.contains(outputIndex + 1)
        else {
            fputs("usage: MarkShot --smoke-render <input.png> --smoke-output <output.png>\n", stderr)
            return true
        }

        let inputURL = URL(fileURLWithPath: arguments[inputIndex + 1])
        let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])

        guard let image = NSImage(contentsOf: inputURL) else {
            fputs("smoke failed: could not read input image\n", stderr)
            return true
        }

        let size = image.pixelSizeForSmoke
        let annotation = Annotation(
            tool: .arrow,
            start: CGPoint(x: size.width * 0.22, y: size.height * 0.25),
            end: CGPoint(x: size.width * 0.78, y: size.height * 0.72),
            color: .systemRed,
            lineWidth: 14
        )

        let rendered = NSImage(size: size)
        rendered.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        AnnotationRenderer.draw(annotation: annotation, in: NSRect(origin: .zero, size: size), imageSize: size)
        rendered.unlockFocus()

        guard let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            fputs("smoke failed: could not render PNG\n", stderr)
            return true
        }

        do {
            try png.write(to: outputURL, options: .atomic)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            print("smoke ok: wrote \(outputURL.path) and copied PNG to clipboard")
        } catch {
            fputs("smoke failed: \(error.localizedDescription)\n", stderr)
        }

        return true
    }
}

private extension NSImage {
    var pixelSizeForSmoke: NSSize {
        if let rep = representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}
