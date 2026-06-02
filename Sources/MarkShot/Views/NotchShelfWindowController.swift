import AppKit
import SwiftUI

@MainActor
final class NotchShelfWindowController {
    private let state: AppState
    private var window: NSPanel?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        MarkShotLog.write("notch window show")
        let panel = window ?? makeWindow()
        position(panel)
        panel.orderFrontRegardless()
    }

    func showCollapsed() {
        MarkShotLog.write("notch window show collapsed")
        state.notchShelfExpanded = false
        let panel = window ?? makeWindow()
        position(panel)
        panel.orderFrontRegardless()
    }

    func showExpanded() {
        MarkShotLog.write("notch window show expanded")
        state.notchShelfExpanded = true
        let panel = window ?? makeWindow()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func refreshPosition(expanded: Bool) {
        guard let window else { return }
        position(window)
    }

    private func makeWindow() -> NSPanel {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let hostingView = NSHostingView(
            rootView: NotchShelfView(
                state: state,
                onExpansionChanged: { [weak self, weak panel] expanded in
                    guard let self, let panel else { return }
                    self.position(panel)
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        panel.contentView = hostingView
        self.window = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.builtInOrMain else { return }
        let size = Self.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        MarkShotLog.write("notch window frame=\(NSStringFromRect(frame)) screen=\(NSStringFromRect(screen.frame))")
        panel.setFrame(frame, display: true, animate: false)
    }

    private static let windowSize = CGSize(width: 960, height: 600)
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    static var builtInOrMain: NSScreen? {
        screens.first(where: { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        }) ?? main ?? screens.first
    }
}
