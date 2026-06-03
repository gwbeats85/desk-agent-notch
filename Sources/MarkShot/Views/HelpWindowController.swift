import AppKit
import SwiftUI

final class HelpWindowController {
    private var window: NSWindow?
    private static var current: HelpWindowController?

    static func show() {
        if let existing = current {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        current = HelpWindowController()
    }

    private init() {
        let view = HelpView { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 460
        let height: CGFloat = 560
        let frame = NSRect(
            x: screen.midX - width / 2,
            y: screen.midY - height / 2,
            width: width,
            height: height
        )

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.identifier = NSUserInterfaceItemIdentifier("MarkShotHelpWindow")
        win.contentViewController = hosting
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    private func close() {
        window?.close()
        window = nil
        Self.current = nil
    }
}

// MARK: - Help View

private struct HelpView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HelpSection("Capture") {
                        HelpRow("Region — global hotkey", key: "Cmd+Opt+4")
                        HelpRow("Full Screen — global hotkey", key: "Cmd+Opt+1")
                        HelpRow("Window — while Desk Agent is focused", key: "Cmd+Opt+2")
                        HelpRow("New board (dot-grid canvas)", key: "Cmd+Opt+B")
                        HelpRow("Delay 3s or 5s", key: "Timer menu in toolbar")
                        HelpRow("Record selected-area video clip", key: "Cmd+Opt+5")
                    }

                    HelpSection("Annotate") {
                        HelpRow("Tools: Pointer, Arrow, Box, Circle, Pen, Text, Redact", key: "")
                        HelpRow("Text — click canvas, type, Enter to place", key: "")
                        HelpRow("Board blocks: Header, Card, Tag, Button, Input", key: "board mode")
                        HelpRow("Undo", key: "Cmd+Z")
                        HelpRow("Redo", key: "Cmd+Shift+Z")
                        HelpRow("Cancel in-progress stroke", key: "Esc")
                        HelpRow("Pick color — red, yellow, black, white, or custom", key: "color row")
                        HelpRow("Stroke width", key: "slider")
                    }

                    HelpSection("Export") {
                        HelpRow("Copy annotated PNG to clipboard", key: "Cmd+C")
                        HelpRow("Save annotated PNG (opens save panel)", key: "Cmd+S")
                        HelpRow("Drag PNG into any app", key: "Drag chip in toolbar")
                        HelpRow("Pin to screen — floating, always on top", key: "Pin button")
                        HelpRow("Clear all pinned screenshots", key: "pin.slash or menu bar")
                    }

                    HelpSection("Record Clip  →  VideoFrame Lab") {
                        HelpRow("1. Hit Cmd+Opt+5 or Record", key: "")
                        HelpRow("2. Pick your area — click Record again to stop", key: "")
                        HelpRow("3. Desk Agent puts the finished .mov in Shelf", key: "")
                        HelpRow("4. Send it to VideoFrame Lab from toolbar", key: "localhost:3000")
                        HelpRow("5. Set frame density, copy AI prompt, export ZIP", key: "")
                    }

                    HelpSection("Menu Bar") {
                        HelpRow("Show / hide toolbar (hotkeys stay active)", key: "menu bar icon")
                        HelpRow("Clear All Pinned", key: "menu bar")
                        HelpRow("Quit", key: "Cmd+Q  or menu bar")
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 10)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Desk Agent")
                .font(.system(size: 15, weight: .semibold))
            Text("Quick Reference")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
        }
    }
}

private struct HelpRow: View {
    let label: String
    let key: String

    init(_ label: String, key: String) {
        self.label = label
        self.key = key
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer()
            if !key.isEmpty {
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
