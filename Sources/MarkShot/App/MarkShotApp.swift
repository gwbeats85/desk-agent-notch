import SwiftUI

@main
struct MarkShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    private var qaAutoStartLiveEnabled: Bool {
        ProcessInfo.processInfo.environment["MARKSHOT_AUTO_START_LIVE"] == "1"
    }

    private var qaAutoStopDelay: TimeInterval? {
        guard let rawDelay = ProcessInfo.processInfo.environment["MARKSHOT_AUTO_STOP_LIVE_SECONDS"] else {
            return nil
        }
        guard let parsed = Double(rawDelay), parsed > 0 else {
            return nil
        }
        return parsed
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 340, minHeight: 68)
                .onAppear {
                    NSApp.setActivationPolicy(.accessory)
                    state.hideToolbar()
                    state.showNotchShelf()
                    if qaAutoStartLiveEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            NotificationCenter.default.post(name: .deskAgentStartTalk, object: nil)
                        }
                        if let autoStopDelay = qaAutoStopDelay {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + autoStopDelay) {
                                NotificationCenter.default.post(name: .deskAgentStartTalk, object: nil)
                            }
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Board") {
                    state.newBoard()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button("Capture Selected Region") {
                    state.captureSelectedRegion()
                }
                .keyboardShortcut("4", modifiers: [.command, .option])

                Button("Capture Full Screen") {
                    state.captureFullScreen()
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Capture Window") {
                    state.captureWindow()
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Divider()

                Button(state.isRecordingClip ? "Stop Clip" : "Record Clip") {
                    state.recordClip()
                }
                .keyboardShortcut("5", modifiers: [.command, .option])

                Divider()

                Button("Pin to Screen") {
                    state.pinCurrentScreenshot()
                }

                Button("Clear All Pinned") {
                    state.clearAllPinned()
                }
                .disabled(state.pinnedCount == 0)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Copy Annotated Image") {
                    state.copyRenderedImageToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command])
            }

            CommandGroup(after: .saveItem) {
                Button("Save Annotated PNG") {
                    state.saveRenderedImage()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }

            CommandGroup(after: .undoRedo) {
                Button("Undo") {
                    state.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Redo") {
                    state.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}
