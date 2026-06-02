import AppKit
import SwiftUI

final class PinnedScreenshotWindowController {
    let id = UUID()
    var onClose: ((UUID) -> Void)?
    private var window: NSWindow?

    private static var tileIndex = 0

    init(image: NSImage) {
        let selfID = id
        let view = PinnedScreenshotView(image: image) { [weak self] in
            guard let self else { return }
            self.onClose?(selfID)
        }

        let hosting = NSHostingController(rootView: view)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth: CGFloat = min(440, screen.width * 0.34)
        let scale = min(maxWidth / max(image.size.width, 1), 1.0)
        let imgWidth = max(180, image.size.width * scale)
        let imgHeight = max(120, image.size.height * scale)

        let tileStep: CGFloat = 28
        let tileOffset = CGFloat(Self.tileIndex % 6) * tileStep
        Self.tileIndex += 1

        let frame = NSRect(
            x: screen.maxX - imgWidth - 20 - tileOffset,
            y: screen.maxY - imgHeight - 20 - tileOffset,
            width: imgWidth,
            height: imgHeight
        )

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.identifier = NSUserInterfaceItemIdentifier("MarkShotPinnedScreenshotWindow")
        win.contentViewController = hosting
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        self.window = win
    }

    func close() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }
}

private struct PinnedScreenshotView: View {
    let image: NSImage
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 6)

            if isHovering {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.65))
                            .frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
