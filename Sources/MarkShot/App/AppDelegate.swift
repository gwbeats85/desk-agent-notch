import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyService = HotkeyService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SmokeTest.runIfRequested() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Desk Agent keeps capture hotkeys available.")
        hotkeyService.register()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MarkShotLog.write("launch requested notch shelf")
            NotificationCenter.default.post(name: .markShotShowNotchShelf, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.unregister()
    }
}
