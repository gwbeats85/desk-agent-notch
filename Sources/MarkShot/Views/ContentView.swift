import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    private let colors: [(String, NSColor, Color)] = [
        ("Red", .systemRed, .red),
        ("Yellow", .systemYellow, .yellow),
        ("Black", .black, .black),
        ("White", .white, .white)
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            if state.baseImage != nil {
                AnnotationCanvasRepresentable()
                    .environmentObject(state)
                    .ignoresSafeArea()
            }

            VStack(spacing: 8) {
                floatingToolBar
            }
            .padding(12)
        }
        .background(Color.clear)
        .background(WindowConfigurator().environmentObject(state))
    }

    private var floatingToolBar: some View {
        VStack(spacing: 6) {
            if state.baseImage == nil {
                HStack(spacing: 6) {
                    captureControls
                    Spacer(minLength: 0)
                    launcherButton("Hide to menu bar", "xmark") { state.hideToolbar() }
                }
            } else {
                HStack(spacing: 7) {
                    annotationControls
                    if state.isBoard {
                        toolbarDivider
                        boardAssetControls
                    }
                    toolbarDivider
                    colorControls
                    toolbarDivider
                    strokeControls
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    compactStatus
                    editControls
                    toolbarDivider
                    exportControls
                    iconButton("Hide", "xmark") { state.hideToolbar() }
                }
            }
        }
        .padding(.horizontal, state.baseImage == nil ? 8 : 10)
        .padding(.vertical, state.baseImage == nil ? 7 : 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.32), radius: 16, x: 0, y: 8)
    }

    private var captureControls: some View {
        HStack(spacing: 4) {
            launcherButton("Region", "viewfinder") { state.captureSelectedRegion() }
                .keyboardShortcut("4", modifiers: [.command, .option])
            launcherButton("Full Screen", "display") { state.captureFullScreen() }
                .keyboardShortcut("1", modifiers: [.command, .option])
            launcherButton("Window", "macwindow") { state.captureWindow() }

            if state.isCapturing || state.isRecordingClip || state.isSendingClipToVideoFrame {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 4)
            }

            toolbarDivider

            launcherButton("Record Clip", "record.circle") { state.recordClip() }
            launcherButton("Open VideoFrame Lab", "film") { state.openVideoFrameLab() }
            if state.isVideoFrameLabActive {
                launcherButton("Stop VideoFrame Lab", "stop.circle") { state.stopVideoFrameLab() }
            }

            if state.lastRecordedClipURL != nil {
                launcherButton("Send last clip to VideoFrame Lab", "paperplane") { state.sendLastClipToVideoFrameLab() }
            }

            Menu {
                Button("3s — Region") { state.captureWithDelay(seconds: 3, mode: .selectedRegion) }
                Button("5s — Region") { state.captureWithDelay(seconds: 5, mode: .selectedRegion) }
                Divider()
                Button("3s — Full Screen") { state.captureWithDelay(seconds: 3, mode: .fullScreen) }
                Button("5s — Full Screen") { state.captureWithDelay(seconds: 5, mode: .fullScreen) }
            } label: {
                Image(systemName: "timer")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Delayed capture")
        }
    }

    private var annotationControls: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.markupTools) { tool in
                Button {
                    state.selectedTool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(state.selectedTool == tool ? .accentColor : .secondary)
                .help(tool.label)
            }
        }
    }

    private var boardAssetControls: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.boardAssetTools) { tool in
                Button {
                    state.selectedTool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(state.selectedTool == tool ? .accentColor : .secondary)
                .help(tool.label)
            }
        }
    }

    private var colorControls: some View {
        HStack(spacing: 8) {
            ForEach(colors, id: \.0) { name, nsColor, color in
                Button {
                    state.selectedColor = nsColor
                } label: {
                    Circle()
                        .fill(color)
                        .overlay(Circle().stroke(Color.secondary, lineWidth: state.selectedColor == nsColor ? 2 : 0.5))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(name)
            }

            ColorPicker("", selection: Binding(
                get: { Color(nsColor: state.selectedColor) },
                set: { state.selectedColor = NSColor($0) }
            ))
            .labelsHidden()
            .frame(width: 34)
            .help("Custom color")
        }
    }

    private var strokeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "lineweight")
            Slider(value: Binding(
                get: { Double(state.strokeWidth) },
                set: { state.strokeWidth = CGFloat($0) }
            ), in: 2...18, step: 1)
            .frame(width: 120)

            Text("\(Int(state.strokeWidth))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
        }
    }

    private var editControls: some View {
        HStack(spacing: 8) {
            iconButton("Undo", "arrow.uturn.backward") { state.undo() }
                .keyboardShortcut("z", modifiers: [.command])

            iconButton("Redo", "arrow.uturn.forward") { state.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Button(role: .destructive) {
                state.clearAnnotations()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 22)
            }
            .help("Clear annotations")
        }
    }

    private var exportControls: some View {
        HStack(spacing: 8) {
            iconButton("Copy", "doc.on.doc") { state.copyRenderedImageToClipboard() }
                .keyboardShortcut("c", modifiers: [.command])
            iconButton("Save", "square.and.arrow.down") { state.saveRenderedImage() }
                .keyboardShortcut("s", modifiers: [.command])

            Text("Drag PNG")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .onDrag {
                    state.dragItemProvider()
                }
                .help("Drag the rendered annotated PNG into another app.")

            Button {
                state.pinCurrentScreenshot()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pin")
                        .font(.system(size: 13, weight: .semibold))
                    if state.pinnedCount > 0 {
                        Text("\(state.pinnedCount)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
                .frame(height: 22)
            }
            .buttonStyle(.bordered)
            .help("Pin to screen — stays floating while you work")

            if state.pinnedCount > 0 {
                Button {
                    state.clearAllPinned()
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .help("Clear all pinned screenshots")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.pinnedCount > 0)
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 26)
    }

    private var compactStatus: some View {
        Text(state.statusMessage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func launcherButton(_ help: String, _ symbolName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .help(help)
    }

    private func iconButton(_ help: String, _ symbolName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

}
