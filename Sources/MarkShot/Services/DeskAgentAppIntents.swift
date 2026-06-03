import AppIntents
import Foundation

@available(macOS 13.0, *)
private enum DeskAgentIntentRouter {
    @MainActor
    static func post(_ name: Notification.Name, status: String) {
        NotificationCenter.default.post(name: name, object: nil)
        NotificationCenter.default.post(name: .markShotHotkeyStatus, object: status)
    }
}

@available(macOS 13.0, *)
struct OpenDeskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Desk Agent"
    static var description = IntentDescription("Show the Desk Agent Notch.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.markShotShowNotchShelf, status: "Opening Desk Agent.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct ShowDeskAgentShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Desk Agent Shelf"
    static var description = IntentDescription("Open the Notch shelf for recent screenshots.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.markShotShowNotchShelf, status: "Opening screenshot shelf.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureDeskAgentRegionIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Region"
    static var description = IntentDescription("Start a Desk Agent region screenshot.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.markShotCaptureRegion, status: "Starting region capture.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct RecordDeskAgentClipIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Clip"
    static var description = IntentDescription("Start a short Desk Agent screen recording.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.markShotRecordClip, status: "Starting clip recording.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct SaveDeskAgentNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Desk Agent Note"
    static var description = IntentDescription("Append text to the Desk Agent Obsidian quick notes inbox.")
    static var openAppWhenRun = false

    @Parameter(title: "Note")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$note) to Desk Agent notes")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing to save.")
        }

        do {
            try AppState.appendQuickNoteToObsidian(trimmed)
            return .result(dialog: "Saved to Desk Agent notes.")
        } catch {
            return .result(dialog: "Could not save the note.")
        }
    }
}

@available(macOS 13.0, *)
struct TalkToHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Hermes"
    static var description = IntentDescription("Start the Desk Agent live voice path from the Notch.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.deskAgentStartTalk, status: "Starting Talk to Hermes.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct AirDropLatestShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "AirDrop Latest Shelf Batch"
    static var description = IntentDescription("Open AirDrop for the latest Desk Agent shelf screenshots.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeskAgentIntentRouter.post(.markShotAirDropLatestShelf, status: "Opening AirDrop for latest shelf batch.")
        return .result()
    }
}

@available(macOS 13.0, *)
struct CheckDeskAgentStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Desk Agent Status"
    static var description = IntentDescription("Check helper, phone, AirSend, and live voice readiness.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        do {
            let status = try await DeskAgentBridgeClient().fetchNotchStatus()
            let message = Self.statusMessage(from: status)
            return .result(dialog: "\(message)")
        } catch {
            return .result(dialog: "Desk Agent helper is not reachable.")
        }
    }

    private static func statusMessage(from status: DeskAgentNotchStatus) -> String {
        var parts: [String] = []

        if !status.activeLiveSessions.isEmpty {
            parts.append("\(status.activeLiveSessions.count) live session\(status.activeLiveSessions.count == 1 ? "" : "s") active")
        } else if status.liveReadiness.isReady {
            parts.append("Talk is ready")
        } else {
            parts.append(status.liveReadiness.compactStatus)
        }

        if status.pairedDevices > 0 {
            parts.append("\(status.pairedDevices) phone\(status.pairedDevices == 1 ? "" : "s") remembered")
        } else {
            parts.append("no phone remembered")
        }

        if !status.airSends.isEmpty {
            parts.append("\(status.airSends.count) AirSend item\(status.airSends.count == 1 ? "" : "s") waiting")
        }

        if status.pendingApprovals > 0 {
            parts.append("\(status.pendingApprovals) approval\(status.pendingApprovals == 1 ? "" : "s") waiting")
        }

        return parts.joined(separator: ", ") + "."
    }
}

@available(macOS 13.0, *)
struct DeskAgentAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDeskAgentIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show \(.applicationName)"
            ],
            shortTitle: "Open Desk Agent",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: CaptureDeskAgentRegionIntent(),
            phrases: [
                "Capture region with \(.applicationName)",
                "Take a screenshot with \(.applicationName)"
            ],
            shortTitle: "Capture Region",
            systemImageName: "viewfinder"
        )

        AppShortcut(
            intent: RecordDeskAgentClipIntent(),
            phrases: [
                "Record clip with \(.applicationName)",
                "Start recording with \(.applicationName)"
            ],
            shortTitle: "Record Clip",
            systemImageName: "record.circle"
        )

        AppShortcut(
            intent: ShowDeskAgentShelfIntent(),
            phrases: [
                "Show shelf in \(.applicationName)",
                "Open shelf in \(.applicationName)"
            ],
            shortTitle: "Show Shelf",
            systemImageName: "tray.full"
        )

        AppShortcut(
            intent: SaveDeskAgentNoteIntent(),
            phrases: [
                "Save note with \(.applicationName)",
                "Add note to \(.applicationName)"
            ],
            shortTitle: "Save Note",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: TalkToHermesIntent(),
            phrases: [
                "Talk to Hermes with \(.applicationName)",
                "Start talking with \(.applicationName)"
            ],
            shortTitle: "Talk to Hermes",
            systemImageName: "waveform.circle"
        )

        AppShortcut(
            intent: AirDropLatestShelfIntent(),
            phrases: [
                "AirDrop latest shelf with \(.applicationName)",
                "Share latest shelf with \(.applicationName)"
            ],
            shortTitle: "AirDrop Shelf",
            systemImageName: "square.and.arrow.up"
        )

        AppShortcut(
            intent: CheckDeskAgentStatusIntent(),
            phrases: [
                "Check \(.applicationName) status",
                "Is \(.applicationName) ready"
            ],
            shortTitle: "Check Status",
            systemImageName: "checkmark.seal"
        )
    }
}
