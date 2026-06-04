import AppKit
import SwiftUI

@MainActor
final class LiveReplyBubbleWindowController {
    private var window: NSPanel?
    private var hideToken = UUID()

    func show(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let panel = window ?? makeWindow()
        let token = UUID()
        hideToken = token
        panel.contentView = NSHostingView(rootView: LiveReplyBubbleView(text: trimmed))
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration(for: trimmed)) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hide()
        }
    }

    func hide() {
        guard let panel = window, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = LiveReplyBubblePanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 4
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        window = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.builtInOrMainForLiveReply else { return }
        let frame = NSRect(
            x: screen.frame.minX + 24,
            y: screen.frame.maxY - Self.windowSize.height - 88,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    private func displayDuration(for text: String) -> TimeInterval {
        min(10, max(4.2, Double(text.count) / 18.0))
    }

    private static let windowSize = CGSize(width: 380, height: 138)
}

private final class LiveReplyBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct LiveReplyBubbleView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.32, green: 0.9, blue: 0.62).opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(red: 0.62, green: 1.0, blue: 0.78))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Live reply")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .textCase(.uppercase)
                Text(text)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 380, height: 138, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.68))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 24, x: 0, y: 12)
    }
}

private extension NSScreen {
    static var builtInOrMainForLiveReply: NSScreen? {
        screens.first(where: { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        }) ?? main ?? screens.first
    }
}
