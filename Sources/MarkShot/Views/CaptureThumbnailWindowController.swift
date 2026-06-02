import AppKit
import SwiftUI

final class CaptureThumbnailWindowController {
    let id = UUID()
    let image: NSImage
    var onOpen: ((UUID, NSImage) -> Void)?
    var onCopy: ((NSImage) -> Void)?
    var onSaveAll: (() -> Void)?
    var onShelf: (() -> Void)?
    var onClose: ((UUID) -> Void)?

    private var window: NSWindow?

    init(image: NSImage, stackIndex: Int) {
        self.image = image
        let selfID = id
        let view = CaptureThumbnailView(
            image: image,
            onOpen: { [weak self] in
                guard let self else { return }
                self.onOpen?(selfID, image)
            },
            onCopy: { [weak self] in
                guard let self else { return }
                self.onCopy?(image)
            },
            onShelf: { [weak self] in
                self?.onShelf?()
            },
            onSaveAll: { [weak self] in
                self?.onSaveAll?()
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.onClose?(selfID)
            }
        )

        let hosting = NSHostingController(rootView: view)
        let frame = Self.frame(for: image, stackIndex: stackIndex)
        hosting.view.frame = NSRect(origin: .zero, size: frame.size)
        hosting.view.autoresizingMask = [.width, .height]

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.identifier = NSUserInterfaceItemIdentifier("MarkShotCaptureThumbnailWindow")
        win.contentViewController = hosting
        win.setContentSize(frame.size)
        win.setFrame(frame, display: true)
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        self.window = win
    }

    func move(toStackIndex stackIndex: Int) {
        guard let window else { return }
        window.setFrame(Self.frame(for: image, stackIndex: stackIndex), display: true, animate: true)
    }

    func close() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    private static func frame(for image: NSImage, stackIndex: Int) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth: CGFloat = 168
        let maxHeight: CGFloat = 122
        let scale = min(maxWidth / max(image.size.width, 1), maxHeight / max(image.size.height, 1), 1)
        let width = max(96, min(maxWidth, image.size.width * scale))
        let height = max(72, min(maxHeight, image.size.height * scale))
        let gap: CGFloat = 12
        let bottomMargin: CGFloat = 22
        let rightMargin: CGFloat = 22
        let stackedY = screen.minY + bottomMargin + CGFloat(stackIndex) * (height + gap)
        let y = min(stackedY, screen.maxY - height - bottomMargin)

        return NSRect(
            x: screen.maxX - width - rightMargin,
            y: y,
            width: width,
            height: height
        )
    }
}

private struct CaptureThumbnailView: View {
    let image: NSImage
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onShelf: () -> Void
    let onSaveAll: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isHovering ? 0.45 : 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture(perform: onOpen)

            if isHovering {
                HStack(spacing: 6) {
                    Button(action: onShelf) {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.68), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Send stack to notch shelf")

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.68), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy screenshot")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.68), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(7)
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
