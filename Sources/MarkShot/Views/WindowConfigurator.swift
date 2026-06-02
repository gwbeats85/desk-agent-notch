import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    @EnvironmentObject private var state: AppState

    func makeNSView(context: Context) -> WindowConfiguratorView {
        WindowConfiguratorView()
    }

    func updateNSView(_ nsView: WindowConfiguratorView, context: Context) {
        nsView.configure(image: state.baseImage)
    }
}

final class WindowConfiguratorView: NSView {
    private var didInitialConfigure = false
    private var lastImageSize: NSSize?

    func configure(image: NSImage?) {
        DispatchQueue.main.async {
            guard let window = self.window else { return }

            if !self.didInitialConfigure {
                window.identifier = NSUserInterfaceItemIdentifier("MarkShotMainWindow")
                window.styleMask = [.borderless]
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                self.fitToolbarOnly(window: window)
                window.orderOut(nil)
                self.didInitialConfigure = true
            }

            // Draggable when pre-capture; annotation canvas needs mouse events when image is loaded
            window.isMovableByWindowBackground = (image == nil)

            guard let image else {
                // Collapse back to toolbar height without moving the window's X/Y
                if self.lastImageSize != nil {
                    self.lastImageSize = nil
                    self.collapseToToolbar(window: window)
                }
                return
            }
            let imageSize = image.pixelSizeForWindowConfig
            guard self.lastImageSize != imageSize else { return }
            self.lastImageSize = imageSize
            self.fit(window: window, to: imageSize)
        }
    }

    private func fit(window: NSWindow, to imageSize: NSSize) {
        guard let screen = Self.targetScreen else { return }

        let available = screen.visibleFrame.insetBy(dx: 72, dy: 54)
        let toolbarHeight: CGFloat = 112
        let scale = min(
            available.width / imageSize.width,
            (available.height - toolbarHeight) / imageSize.height,
            1
        )

        let width = max(720, min(available.width, imageSize.width * scale))
        let height = max(520, min(available.height, imageSize.height * scale + toolbarHeight))
        let frame = NSRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private func fitToolbarOnly(window: NSWindow) {
        guard let screen = Self.targetScreen else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = min(420, visible.width - 96)
        let height: CGFloat = 68
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + 86,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private func collapseToToolbar(window: NSWindow) {
        let current = window.frame
        let height: CGFloat = 68
        let frame = NSRect(
            x: current.minX,
            y: current.minY + (current.height - height),
            width: current.width,
            height: height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private static var targetScreen: NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            lhs.frame.minY < rhs.frame.minY
        } ?? NSScreen.main
    }
}

private extension NSImage {
    var pixelSizeForWindowConfig: NSSize {
        if let rep = representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}
