import AppKit
@preconcurrency import AVFoundation
import EventKit
import Network
import Quartz
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum NotchModule: String {
    case home
    case shelf
    case chat
    case notes
    case music
    case switchboard
}

private enum MediaSource: String {
    case spotify
    case plex
    case music
}

private func musicBrowseWebURL(for source: MediaSource) -> String {
    switch source {
    case .spotify:
        return "https://open.spotify.com"
    case .plex:
        return "https://app.plex.tv/desktop/"
    case .music:
        return "https://music.apple.com"
    }
}

private func musicWebViewMatchesSource(_ webView: WKWebView?, source: MediaSource) -> Bool {
    guard let host = webView?.url?.host?.lowercased(), !host.isEmpty else { return false }
    switch source {
    case .spotify:
        return host.contains("spotify")
    case .plex:
        return host.contains("plex")
    case .music:
        return host.contains("music.apple") || host.contains("apple.com")
    }
}

private enum NotchChatRole: String, Codable {
    case user
    case assistant
    case system
}

private enum NotchChatAttachmentKind: String, Codable {
    case localImage
    case localVideo
    case localFile
    case localFolder
    case remoteImage
    case remoteFile
}

private struct NotchChatAttachment: Identifiable, Codable {
    let id: UUID
    let url: URL
    let kind: NotchChatAttachmentKind

    init(id: UUID = UUID(), url: URL, kind: NotchChatAttachmentKind) {
        self.id = id
        self.url = url
        self.kind = kind
    }

    var title: String {
        url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
    }

    var isLocalImage: Bool {
        kind == .localImage
    }

    var symbol: String {
        switch kind {
        case .localImage, .remoteImage: return "photo"
        case .localVideo: return "film"
        case .localFolder: return "folder"
        case .localFile, .remoteFile: return "doc"
        }
    }
}

private struct NotchChatMessage: Identifiable, Codable {
    let id: UUID
    let role: NotchChatRole
    let text: String
    let attachments: [NotchChatAttachment]
    let createdAt: Date
    let source: String?

    init(id: UUID = UUID(), role: NotchChatRole, text: String, attachments: [NotchChatAttachment] = [], createdAt: Date = Date(), source: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.source = source
    }
}

private struct CollapsedNotchStatus {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let isActive: Bool
}

private struct NotchInlineAlert {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let expiresAt: Date
}

private enum DeskAgentLocalPaths {
    static let homeURL = FileManager.default.homeDirectoryForCurrentUser
    static let homePath = homeURL.path

    static func env(_ key: String, fallback: String) -> String {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    static var musicServerURL: String {
        env("DESK_AGENT_MUSIC_SERVER_URL", fallback: "")
    }

    static var sourcePath: String {
        env("DESK_AGENT_SOURCE_PATH", fallback: "\(homePath)/Projects/markshot-suite/MarkShot")
    }

    static var appsWorkspacePath: String {
        env("DESK_AGENT_APPS_PATH", fallback: "\(homePath)/Workspaces/apps")
    }

    static var notesPath: String {
        env("DESK_AGENT_NOTES_PATH", fallback: obsidianVaultURL.path)
    }

    static var obsidianVaultURL: URL {
        let configured = env("DESK_AGENT_OBSIDIAN_VAULT", fallback: "")
        if !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        let candidates = [
            "\(homePath)/Library/Mobile Documents/iCloud~md~obsidian/Documents/1note",
            "\(homePath)/Documents/1note",
            "\(homePath)/Documents/DeskAgentVault"
        ]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: existing, isDirectory: true)
        }
        return URL(fileURLWithPath: candidates[0], isDirectory: true)
    }

    static var servicesRegistryPath: String {
        if let configured = ProcessInfo.processInfo.environment["DESK_AGENT_SERVICES_YAML"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        let candidates = [
            "\(homePath)/.desk-agent/SERVICES.yaml",
            "\(homePath)/Workspaces/m5-notes/network/SERVICES.yaml",
            "\(homePath)/Workspaces/codex-home/SERVICES.yaml"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    static var n8nURL: String {
        env("DESK_AGENT_N8N_URL", fallback: "http://127.0.0.1:5678")
    }

    static var glanceURL: String {
        env("DESK_AGENT_GLANCE_URL", fallback: "http://127.0.0.1:7575")
    }

    static var skillsReferencePaths: [String] {
        if let configured = ProcessInfo.processInfo.environment["DESK_AGENT_SKILLS_REFERENCES"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured.split(separator: ":").map(String.init)
        }
        return [
            "\(homePath)/.desk-agent/WHEN_TO_USE_WHICH_SKILL.md",
            "\(homePath)/.desk-agent/skills-inventory.md"
        ]
    }

    static var switchboardAppPaths: [String] {
        [
            "\(homePath)/Applications/ServiceSwitchboard.app",
            "/Applications/ServiceSwitchboard.app",
            "\(appsWorkspacePath)/ServiceSwitchboard/dist/ServiceSwitchboard.app"
        ]
    }

    static var handoffActivityType: String {
        env(
            "DESK_AGENT_HANDOFF_ACTIVITY_TYPE",
            fallback: "\(Bundle.main.bundleIdentifier ?? "com.deskagent.MarkShot").hermesConversation"
        )
    }
}

struct NotchShelfView: View {
    @ObservedObject var state: AppState
    let onExpansionChanged: (Bool) -> Void

    @AppStorage("markshot.notch.quickNoteDraft") private var quickNoteDraft = ""
    @AppStorage("markshot.notch.musicFolderPath") private var musicFolderPath = ""
    @AppStorage("markshot.notch.musicServerURL") private var musicServerURL = DeskAgentLocalPaths.musicServerURL
    @AppStorage("markshot.notch.chatSessionId") private var hermesSessionId = ""
    @AppStorage("markshot.notch.chatHistoryJSON") private var chatHistoryJSON = ""
    @AppStorage("deskagent.notch.conversationId") private var deskAgentConversationId = ""
    @AppStorage("deskagent.notch.wakeListeningEnabled") private var wakeListeningEnabled = false
    @AppStorage("deskagent.notch.lastBridgeConversationTurnID") private var lastBridgeConversationTurnID = ""
    @State private var activePulse = false
    @State private var activeModule: NotchModule = .chat
    @State private var dragOffset: CGFloat = 0.0
    @State private var hasTriggeredHaptic = false
    
    @State private var isDndActive = false
    @State private var isLampActive = false
    @State private var mediaSource: MediaSource = .spotify
    @State private var visualizerHeights: [CGFloat] = Array(repeating: 4.0, count: 26)

    @State private var chatDraft = ""
    @State private var chatMessages: [NotchChatMessage] = [
        NotchChatMessage(role: .system, text: "Hermes ready. Ask quick, keep moving.")
    ]
    @State private var isSendingToHermes = false
    @State private var hermesStartedAt: Date?
    @State private var hermesElapsedSeconds = 0
    @State private var chatFocusMode = false
    @State private var quickNoteFocusMode = false
    @State private var chatPendingAttachments: [NotchChatAttachment] = []
    @State private var chatPopoutController: HermesChatPopoutController?
    @State private var hermesSidecarController: HermesSidecarWindowController?
    @State private var liveReadiness: DeskAgentLiveReadiness?
    @State private var notchBridgeStatus: DeskAgentNotchStatus?
    @State private var seenBridgeConversationTurnIDs: Set<String> = []
    @State private var lastChatLiveUserTranscript = ""
    @State private var lastChatLiveAssistantTranscript = ""
    @State private var isCheckingLiveReadiness = false
    @State private var liveReadinessError = ""
    @State private var isChangingLiveSession = false
    @State private var lastBridgeRefreshAt = Date.distantPast
    @State private var musicSearch = ""
    @State private var musicTracks: [NotchMusicTrack] = []
    @State private var selectedMusicTrackID: String?
    @State private var isLoadingMusic = false
    @State private var musicScanID = UUID()
    @State private var scannedMusicFolderPath = ""
    @State private var lastOpenedMusicTrackID: String?
    @State private var musicPlayer: AVAudioPlayer?
    @State private var musicElapsedSeconds = 0
    @State private var musicDurationSeconds = 0
    @State private var externalNowPlayingTitle = ""
    @State private var externalNowPlayingSubtitle = ""
    @State private var lastExternalMusicSyncAt = Date.distantPast
    @State private var lastPlexProgressSyncAt = Date.distantPast
    @State private var spotifyPlaybackActive = false
    @State private var plexPlaybackActive = false
    @State private var visualizerPhase: Double = 0.0
    @State private var switchboardSearch = ""
    @State private var switchboardServices: [NotchSwitchboardService] = []
    @State private var switchboardReachability: [String: Bool] = [:]
    @State private var isCheckingSwitchboard = false
    @State private var switchboardLastChecked: Date?
    @State private var inlineAlert: NotchInlineAlert?
    @StateObject private var camera = NotchCameraController()
    @StateObject private var liveVoice = NotchLiveVoiceController()
    @StateObject private var wakePhrase = NotchWakePhraseController()
    @StateObject private var reminders = NotchRemindersStore()
    @StateObject private var calendarAgenda = NotchCalendarStore()
    @State private var liveVoiceBridgeMounted = false
    @State private var qaAutoStopTriggered = false

    private let hermesClient = HermesDirectClient()
    private let bridgeClient = DeskAgentBridgeClient()
    private let maxLocalChatMessages = 80
    private let maxPersistedChatMessages = 20

    private var qaAutoStartLiveEnabled: Bool {
        ProcessInfo.processInfo.environment["MARKSHOT_AUTO_START_LIVE"] == "1"
    }

    private var qaAutoStopLiveDelay: TimeInterval? {
        guard let rawDelay = ProcessInfo.processInfo.environment["MARKSHOT_AUTO_STOP_LIVE_SECONDS"] else {
            return nil
        }
        guard let parsed = Double(rawDelay), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private var totalCount: Int {
        state.shelfBatches.reduce(0) { $0 + $1.itemCount }
    }

    private var activePhoneSession: DeskAgentActiveLiveSession? {
        notchBridgeStatus?.activeLiveSessions.first { $0.source == "iphone" }
    }

    private var phoneLiveVoiceActive: Bool {
        activePhoneSession != nil
    }

    private var phoneSessionState: String {
        guard let session = activePhoneSession else { return "idle" }
        guard let diagnostic = session.lastDiagnostic else { return "listening" }
        switch diagnostic.event {
        case "session_started", "setup_sent":
            return "connecting"
        case "setup_complete", "mic_frame", "user_transcript", "mic_suppressed", "assistant_turn_complete":
            return "listening"
        case "assistant_audio", "assistant_transcript":
            return "replying"
        case "tool_reply", "tool_reply_sanitized", "tool_error_sanitized", "live-tool", "realtime-tool":
            return "thinking"
        case "stop_requested":
            return "stopped"
        default:
            return "listening"
        }
    }

    private var expanded: Bool {
        state.notchShelfExpanded
    }

    var body: some View {
        let currentStretch: CGFloat = {
            if !expanded {
                return dragOffset > 0 ? (dragOffset / (1.0 + dragOffset / 120.0)) : 0.0
            } else {
                if dragOffset < 0 {
                    return dragOffset / (1.0 + abs(dragOffset) / 120.0)
                } else {
                    return dragOffset / (1.0 + dragOffset / 120.0)
                }
            }
        }()
        
        let positiveStretch = max(0.0, currentStretch)
        let currentWidth = expanded ? (900.0 - currentStretch * 0.45) : (528.0 - currentStretch * 0.45)
        let currentHeight = expanded ? (440.0 + currentStretch) : (38.0 + currentStretch)
        let currentCornerRadius = expanded ? (28.0 + currentStretch * 0.15) : (18.0 + currentStretch * 0.22)
        
        return ZStack(alignment: .top) {
            // Unified morphing background surface
            compactNotchSurface(
                flareWidth: 16,
                flareHeight: 20,
                bottomCornerRadius: currentCornerRadius
            )
            .frame(width: currentWidth, height: currentHeight)
            .shadow(color: Color.black.opacity(expanded ? 0.35 : (currentStretch > 0 ? 0.2 * (currentStretch / 60.0) : 0.0)), radius: 10, y: 5)
            // Expansion is intentionally gesture-only; visible controls must stay out of the hardware notch center.
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { value in
                        let translation = value.translation
                        if !expanded {
                            // Pull down to expand
                            if translation.height > 0 {
                                dragOffset = translation.height
                                let stretch = dragOffset / (1.0 + dragOffset / 120.0)
                                if stretch > 40.0 && !hasTriggeredHaptic {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    hasTriggeredHaptic = true
                                } else if stretch <= 40.0 && hasTriggeredHaptic {
                                    hasTriggeredHaptic = false
                                }
                            }
                        } else {
                            // Expanded: Drag UP to collapse, or Drag DOWN to rubber-band/overscroll
                            dragOffset = translation.height
                            let absTrans = abs(dragOffset)
                            let stretch = absTrans / (1.0 + absTrans / 120.0)
                            if stretch > 40.0 && !hasTriggeredHaptic {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                hasTriggeredHaptic = true
                            } else if stretch <= 40.0 && hasTriggeredHaptic {
                                hasTriggeredHaptic = false
                            }
                        }
                    }
                    .onEnded { value in
                        if !expanded {
                            let stretch = dragOffset / (1.0 + dragOffset / 120.0)
                            if stretch > 40.0 {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                                    state.notchShelfExpanded = true
                                }
                                onExpansionChanged(true)
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                                    dragOffset = 0.0
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                            }
                        } else {
                            if dragOffset < 0 {
                                // Pull up to collapse
                                let absTrans = abs(dragOffset)
                                let stretch = absTrans / (1.0 + absTrans / 120.0)
                                if stretch > 40.0 {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                                        state.notchShelfExpanded = false
                                    }
                                    onExpansionChanged(false)
                                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                                } else {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                                        dragOffset = 0.0
                                    }
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                                }
                            } else {
                                // Pull down overscroll - snap to collapse/minimize on release past threshold
                                let stretch = dragOffset / (1.0 + dragOffset / 120.0)
                                if stretch > 40.0 {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                                        state.notchShelfExpanded = false
                                    }
                                    onExpansionChanged(false)
                                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                                } else {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                                        dragOffset = 0.0
                                    }
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                                }
                            }
                        }
                        hasTriggeredHaptic = false
                        dragOffset = 0.0
                    }
            )
            
            // Content morphing using transitions
            ZStack(alignment: .top) {
                expandedShelf(stretch: positiveStretch)
                    .opacity(expanded ? 1.0 : 0.0)
                    .scaleEffect(expanded ? 1.0 : 0.985, anchor: .top)
                    .allowsHitTesting(expanded)
                
                if !expanded {
                    collapsedShelf
                        .offset(y: currentStretch * 0.15) // Liquid offset
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if shouldShowCaptureDock(expanded: expanded) {
                    captureDock
                        .offset(y: expanded ? (440.0 + positiveStretch + 8) : 42)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(width: currentWidth, height: currentHeight, alignment: .top)


        }
        .frame(width: 960, height: 600, alignment: .top)
        .background {
            if liveVoiceBridgeMounted {
                NotchLiveVoiceWebView(controller: liveVoice)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            applyRequestedModuleIfNeeded()
            if state.notchListeningEnabled || liveVoice.isActive {
                mountLiveVoiceBridgeIfNeeded()
            }
            configureWakePhrase()
            restoreChatHistory()
            loadSwitchboardServices()
            reminders.load()
            calendarAgenda.load()
            refreshLiveReadiness()
            if qaAutoStartLiveEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MarkShotLog.write("qa auto start live requested from notch shelf")
                    triggerQAStartLive(attempt: 0)
                }
                if let autoStopDelay = qaAutoStopLiveDelay {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + autoStopDelay) {
                        MarkShotLog.write("qa auto stop live timer fired after \(autoStopDelay)s")
                        handleAutoStopRequested()
                    }
                }
            }
            if wakeListeningEnabled, !liveVoice.isActive, !state.notchListeningEnabled {
                startWakePhraseListening()
            }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                activePulse = true
            }
        }
        .onChange(of: chatMessages.count) { _ in
            persistChatHistory()
        }
        .onChange(of: liveVoice.liveState) { liveState in
            syncNotchListening(with: liveState)
        }
        .onChange(of: activeModule) { module in
            if module == .home {
                reminders.load()
                calendarAgenda.load()
            }
        }
        .onChange(of: state.requestedNotchModule) { _ in
            applyRequestedModuleIfNeeded()
        }
        .onChange(of: state.statusMessage) { message in
            showInlineAlert(for: message)
        }
        .onChange(of: wakeListeningEnabled) { enabled in
            if enabled {
                startWakePhraseListening()
            } else {
                wakePhrase.stop()
                state.statusMessage = "Wake listening is off."
            }
        }
        .onChange(of: mediaSource) { newSource in
            syncDisplayedPlaybackActive()
            refreshActiveMediaSourceStateForSource(newSource)
        }
        .onChange(of: state.notchPlaybackActive) { isPlaying in
            if !isPlaying {
                resetVisualizerHeights()
            }
        }
        .onChange(of: liveVoice.lastFinalUserTranscript) { transcript in
            guard !transcript.isEmpty else { return }
            if shouldStopLiveSession(from: transcript) {
                MarkShotLog.write("live user transcript matched stop phrase len=\(transcript.count)")
                state.statusMessage = "Stopping live voice from voice command..."
                stopLiveSession()
                return
            }
            MarkShotLog.write("live user transcript finalized for chat len=\(transcript.count)")
            appendLiveVoiceTranscript(role: .user, transcript: transcript)
            state.statusMessage = "Heard: \(transcript)"
        }
        .onChange(of: liveVoice.lastFinalAssistantTranscript) { transcript in
            guard !transcript.isEmpty else { return }
            MarkShotLog.write("live assistant transcript finalized for chat len=\(transcript.count)")
            appendLiveVoiceTranscript(role: .assistant, transcript: transcript)
            state.statusMessage = "Live reply: \(transcript)"
        }
        .onReceive(NotificationCenter.default.publisher(for: .deskAgentStartTalk)) { _ in
            startTalkFromShortcut()
        }
        .userActivity(DeskAgentLocalPaths.handoffActivityType) { activity in
            activity.title = "Desk Agent Hermes"
            activity.isEligibleForHandoff = true
            activity.userInfo = [
                "conversationId": ensureDeskAgentConversationId(),
                "module": activeModule.rawValue,
                "surface": "mac-notch"
            ]
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            expireInlineAlertIfNeeded(now)
            refreshBridgeStatusIfNeeded(now: now)

            refreshActiveMediaSourceStateIfNeeded(now: now)

            if musicPlayer != nil, mediaSource == .music, activeModule == .music || state.notchPlaybackActive {
                updateMusicProgress()
            }

            guard isSendingToHermes, let hermesStartedAt else {
                hermesElapsedSeconds = 0
                return
            }
            hermesElapsedSeconds = max(0, Int(now.timeIntervalSince(hermesStartedAt)))
        }
    }

    private func applyRequestedModuleIfNeeded() {
        guard let rawValue = state.requestedNotchModule,
              let module = NotchModule(rawValue: rawValue)
        else { return }

        activeModule = module
        state.requestedNotchModule = nil
    }

    private var collapsedShelf: some View {
        HStack(spacing: 0) {
            NotchControlButtonView(
                title: state.notchListeningEnabled ? "Talk listening on" : "Talk listening off",
                symbol: state.notchListeningEnabled ? "waveform.circle.fill" : "waveform.circle",
                isActive: state.notchListeningEnabled,
                activeColor: Color(red: 0.32, green: 0.9, blue: 0.62),
                activePulse: activePulse
            ) {
                toggleNotchListening()
            }
            .frame(width: 28, alignment: .leading)

            collapsedStatusDisplay
                .padding(.leading, 10)

            Spacer(minLength: 0)
            
            NotchControlButtonView(
                title: "Open Hermes Sidecar",
                symbol: "sidebar.right",
                isActive: false,
                activeColor: Color(red: 0.74, green: 0.56, blue: 1.0),
                activePulse: activePulse
            ) {
                openHermesSidecar()
            }
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .frame(width: 496, height: 38, alignment: .top)
    }

    private var collapsedStatusDisplay: some View {
        let status = collapsedStatus
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(status.tint.opacity(status.isActive ? 0.22 : 0.12))
                Image(systemName: status.symbol)
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 16, height: 16)
            .shadow(color: status.tint.opacity(status.isActive && activePulse ? 0.38 : 0.0), radius: 7, y: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text(status.title)
                    .font(.system(size: 8.5, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(status.detail)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: 156, height: 26)
        .scaleEffect(status.isActive && activePulse ? 1.015 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: status.title)
        .animation(.easeInOut(duration: 0.55), value: activePulse)
        .help("\(status.title): \(status.detail)")
    }

    private var collapsedStatus: CollapsedNotchStatus {
        if isSendingToHermes {
            return CollapsedNotchStatus(
                symbol: "sparkles",
                title: "Hermes",
                detail: hermesThinkingLabel.replacingOccurrences(of: "Hermes is ", with: ""),
                tint: Color(red: 0.62, green: 0.82, blue: 1.0),
                isActive: true
            )
        }

        if isChangingLiveSession || state.notchListeningEnabled || liveVoice.isActive || phoneLiveVoiceActive {
            return CollapsedNotchStatus(
                symbol: liveVoicePulseSymbol,
                title: "Live",
                detail: liveBridgeStatusTitle.replacingOccurrences(of: "Live voice ", with: ""),
                tint: liveBridgeStatusColor,
                isActive: true
            )
        }

        if !chatPendingAttachments.isEmpty {
            let count = chatPendingAttachments.count
            return CollapsedNotchStatus(
                symbol: "paperclip.circle.fill",
                title: "Attached",
                detail: "\(count) item\(count == 1 ? "" : "s")",
                tint: Color(red: 0.42, green: 0.92, blue: 0.78),
                isActive: true
            )
        }

        if let latestAirSend {
            return CollapsedNotchStatus(
                symbol: latestAirSend.kind == "image" ? "photo.badge.arrow.down" : "iphone.and.arrow.forward",
                title: "AirSend",
                detail: latestAirSend.kind.capitalized,
                tint: Color(red: 0.74, green: 0.56, blue: 1.0),
                isActive: true
            )
        }

        if state.isRecordingClip {
            return CollapsedNotchStatus(
                symbol: "record.circle",
                title: "Recording",
                detail: "click stop",
                tint: Color(red: 1.0, green: 0.38, blue: 0.34),
                isActive: true
            )
        }

        if let inlineAlert, inlineAlert.expiresAt > Date() {
            return CollapsedNotchStatus(
                symbol: inlineAlert.symbol,
                title: inlineAlert.title,
                detail: inlineAlert.detail,
                tint: inlineAlert.tint,
                isActive: true
            )
        }

        if totalCount > 0 {
            return CollapsedNotchStatus(
                symbol: "tray.full.fill",
                title: "Shelf",
                detail: "\(totalCount) item\(totalCount == 1 ? "" : "s")",
                tint: Color(red: 1.0, green: 0.78, blue: 0.36),
                isActive: false
            )
        }

        if let notchBridgeStatus, notchBridgeStatus.pendingApprovals > 0 {
            let count = notchBridgeStatus.pendingApprovals
            return CollapsedNotchStatus(
                symbol: "checklist",
                title: "Review",
                detail: "\(count) waiting",
                tint: Color(red: 1.0, green: 0.72, blue: 0.36),
                isActive: true
            )
        }

        if notchBridgeStatus?.pairedDevices ?? 0 > 0 {
            return CollapsedNotchStatus(
                symbol: "iphone.gen3",
                title: "Phone",
                detail: "paired",
                tint: Color(red: 0.32, green: 0.9, blue: 0.62),
                isActive: false
            )
        }

        if !liveReadinessError.isEmpty {
            return CollapsedNotchStatus(
                symbol: "wifi.exclamationmark",
                title: "Live",
                detail: "helper off",
                tint: .orange,
                isActive: false
            )
        }

        return CollapsedNotchStatus(
            symbol: "checkmark.circle.fill",
            title: "Ready",
            detail: liveReadiness?.isReady == true ? "live ready" : "idle",
            tint: Color.white.opacity(0.46),
            isActive: false
        )
    }

    private func showInlineAlert(for message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != inlineAlert?.detail else { return }

        let lowercased = trimmed.lowercased()
        let isFailure = lowercased.contains("failed") ||
            lowercased.contains("blocked") ||
            lowercased.contains("not reachable") ||
            lowercased.contains("offline") ||
            lowercased.contains("unavailable") ||
            lowercased.contains("error")
        let isWaiting = lowercased.contains("loading") ||
            lowercased.contains("starting") ||
            lowercased.contains("checking") ||
            lowercased.contains("waiting") ||
            lowercased.contains("sync")

        let title: String
        let symbol: String
        let tint: Color
        let duration: TimeInterval
        if isFailure {
            title = "Alert"
            symbol = "exclamationmark.triangle.fill"
            tint = Color(red: 1.0, green: 0.62, blue: 0.28)
            duration = 7
        } else if isWaiting {
            title = "Working"
            symbol = "arrow.triangle.2.circlepath"
            tint = Color(red: 0.62, green: 0.82, blue: 1.0)
            duration = 5
        } else {
            title = "Update"
            symbol = "checkmark.circle.fill"
            tint = Color(red: 0.32, green: 0.9, blue: 0.62)
            duration = 4
        }

        inlineAlert = NotchInlineAlert(
            symbol: symbol,
            title: title,
            detail: Self.compactAlertDetail(trimmed),
            tint: tint,
            expiresAt: Date().addingTimeInterval(duration)
        )
    }

    private func expireInlineAlertIfNeeded(_ now: Date) {
        guard let inlineAlert, inlineAlert.expiresAt <= now else { return }
        self.inlineAlert = nil
    }

    private static func compactAlertDetail(_ message: String) -> String {
        let collapsed = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 34 else { return collapsed }
        return String(collapsed.prefix(31)) + "..."
    }

    private func expandedShelf(stretch: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    topActionCluster
                        .frame(maxWidth: .infinity, alignment: .leading)

                    moduleContent(stretch: stretch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                        .clipped()
                        .animation(.easeInOut(duration: 0.14), value: activeModule)
                }
                .padding(.leading, 28)
                .padding(.trailing, 62)
                .padding(.top, 12)
                .padding(.bottom, activeModule == .chat && chatFocusMode ? 8 : 34)

                rightRail
                    .padding(.top, 50)
                    .padding(.trailing, 18)
            }
            .frame(width: 868, height: 440.0 + stretch, alignment: .topLeading)
            

        }
        .frame(width: 868, height: 440.0 + stretch)
    }

    private var topActionCluster: some View {
        HStack(spacing: 8) {
            NotchControlButtonView(
                title: state.notchListeningEnabled ? "Listening on" : "Listening off",
                symbol: state.notchListeningEnabled ? "waveform.circle.fill" : "waveform.circle",
                isActive: state.notchListeningEnabled,
                activeColor: Color(red: 0.32, green: 0.9, blue: 0.62),
                activePulse: activePulse
            ) {
                toggleNotchListening()
            }

            if wakeListeningEnabled {
                ModuleIconButtonView(
                    title: "Wake listening on",
                    symbol: "ear.fill",
                    isActive: true
                ) {
                    toggleWakeListening()
                }
            }

            bottomModuleDock

            Spacer(minLength: 0)

            NotchControlButtonView(
                title: "Open Hermes Sidecar",
                symbol: "sidebar.right",
                isActive: false,
                activeColor: Color(red: 0.74, green: 0.56, blue: 1.0),
                activePulse: activePulse
            ) {
                openHermesSidecar()
            }

            ModuleIconButtonView(title: "Quit Desk Agent", symbol: "power", isActive: false) {
                confirmQuitDeskAgent()
            }

        }
    }

    private func shouldShowCaptureDock(expanded: Bool) -> Bool {
        state.isCapturing ||
        state.isRecordingClip ||
        (expanded && activeModule == .shelf)
    }

    private var captureDock: some View {
        HStack(spacing: 8) {
            captureDockButton("Capture region", "viewfinder", isActive: state.isCapturing) {
                activeModule = .shelf
                state.captureSelectedRegion()
            }
            captureDockButton("Capture screen", "display", isActive: false) {
                activeModule = .shelf
                state.captureFullScreen()
            }
            captureDockButton("Capture window", "macwindow", isActive: false) {
                activeModule = .shelf
                state.captureWindow()
            }
            Divider()
                .frame(height: 24)
                .overlay(Color.white.opacity(0.16))
            captureDockButton(state.isRecordingClip ? "Stop clip" : "Record clip", state.isRecordingClip ? "stop.circle.fill" : "record.circle", isActive: state.isRecordingClip) {
                activeModule = .shelf
                state.recordClip()
            }
            if state.lastRecordedClipURL != nil {
                captureDockButton("Send clip to Frame Lab", "paperplane", isActive: state.isSendingClipToVideoFrame) {
                    activeModule = .shelf
                    state.sendLastClipToVideoFrameLab()
                }
            } else {
                captureDockButton("Open Frame Lab", "film", isActive: state.isVideoFrameLabActive) {
                    activeModule = .shelf
                    state.openVideoFrameLab()
                }
            }
            captureDockButton("Preview latest", "eye", isActive: false) {
                activeModule = .shelf
                state.previewLatestShelfBatch()
            }
            captureDockButton("AirDrop latest", "square.and.arrow.up", isActive: false) {
                activeModule = .shelf
                state.airDropLatestShelfBatch()
            }
            if state.lastRecordedClipURL != nil {
                captureDockButton("Reveal last clip", "folder", isActive: false) {
                    state.revealLastClipInFinder()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func captureDockButton(_ title: String, _ symbol: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isActive ? Color.black.opacity(0.9) : Color.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(isActive ? Color(red: 1.0, green: 0.78, blue: 0.36) : Color.black.opacity(0.58))
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .opacity(isActive ? 0.28 : 0.18)
                        )
                        .shadow(color: Color.black.opacity(0.36), radius: 12, x: 0, y: 8)
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(isActive ? 0.2 : 0.1), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
    }

    private func moduleContent(stretch: CGFloat) -> some View {
        Group {
            switch activeModule {
            case .home:
                homeContent(stretch: stretch)
            case .shelf:
                shelfContent(stretch: stretch)
            case .chat:
                chatPeek(stretch: stretch)
            case .notes:
                notesContent(stretch: stretch)
            case .music:
                musicContent(stretch: stretch)
            case .switchboard:
                switchboardContent(stretch: stretch)
            }
        }
    }

    private var rightRail: some View {
        VStack(spacing: 13) {
            if let latestAirSend {
                RailActionButtonView(
                    title: "Import \(latestAirSend.kind.capitalized) AirSend",
                    symbol: latestAirSend.kind == "image" ? "photo.badge.arrow.down" : "iphone.and.arrow.forward"
                ) {
                    importLatestAirSend()
                }
            }

            switch activeModule {
            case .home:
                RailActionButtonView(title: "Refresh services", symbol: "arrow.clockwise") {
                    refreshSwitchboardHealth()
                }
                RailActionButtonView(title: "Open Switchboard", symbol: "arrow.up.forward.app") {
                    openFullSwitchboard()
                }
                RailActionButtonView(title: "Open registry", symbol: "doc.text.magnifyingglass") {
                    revealSwitchboardRegistry()
                }
            case .notes:
                RailActionButtonView(title: "Save to Obsidian", symbol: "checkmark") {
                    saveQuickNote()
                }
                RailActionButtonView(
                    title: quickNoteFocusMode ? "Compact note" : "Focus note",
                    symbol: quickNoteFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        quickNoteFocusMode.toggle()
                    }
                }
                RailActionButtonView(title: "Copy note", symbol: "arrow.down.doc") {
                    copyQuickNote()
                }
                RailActionButtonView(title: "Capture region", symbol: "viewfinder") {
                    state.captureSelectedRegion()
                }
                RailActionButtonView(title: state.isRecordingClip ? "Stop clip" : "Record clip", symbol: state.isRecordingClip ? "stop.circle.fill" : "record.circle") {
                    state.recordClip()
                }
                RailActionButtonView(title: "Clear note", symbol: "xmark") {
                    quickNoteDraft = ""
                }
            case .shelf:
                if state.isRecordingClip {
                    RailActionButtonView(title: "Stop clip", symbol: "stop.circle.fill") {
                        state.recordClip()
                    }
                }
                if state.lastRecordedClipURL != nil {
                    RailActionButtonView(title: "Send clip to Frame Lab", symbol: "paperplane") {
                        state.sendLastClipToVideoFrameLab()
                    }
                } else {
                    RailActionButtonView(title: "Open Frame Lab", symbol: "film") {
                        state.openVideoFrameLab()
                    }
                }
                RailActionButtonView(title: "Preview latest", symbol: "eye") {
                    state.previewLatestShelfBatch()
                }
                RailActionButtonView(title: "AirDrop latest", symbol: "square.and.arrow.up") {
                    state.airDropLatestShelfBatch()
                }
                RailActionButtonView(title: "Copy latest batch", symbol: "arrow.down.doc") {
                    state.copyLatestShelfBatchToClipboard()
                }
                RailActionButtonView(title: "Clear shelf", symbol: "trash") {
                    state.clearShelf()
                }
            case .chat:
                RailActionButtonView(title: "New chat", symbol: "plus") {
                    resetHermesChat()
                }
                RailActionButtonView(title: "Archive chat", symbol: "archivebox") {
                    archiveChatTranscriptToObsidian()
                }
                RailActionButtonView(title: "Copy transcript", symbol: "doc.on.doc") {
                    copyChatTranscript()
                }
                RailActionButtonView(
                    title: "Pop out chat",
                    symbol: "rectangle.on.rectangle"
                ) {
                    openHermesPopout()
                }
                RailActionButtonView(
                    title: "Sidecar chat",
                    symbol: "sidebar.right"
                ) {
                    openHermesSidecar()
                }
                RailActionButtonView(
                    title: chatFocusMode ? "Compact chat" : "Focus chat",
                    symbol: chatFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        chatFocusMode.toggle()
                    }
                }
            case .music:
                RailActionButtonView(title: "Reveal folder", symbol: "arrow.up.forward.square") {
                    revealMusicFolder()
                }
            case .switchboard:
                RailActionButtonView(title: "Refresh services", symbol: "arrow.clockwise") {
                    refreshSwitchboardHealth()
                }
                RailActionButtonView(title: "Open Switchboard", symbol: "arrow.up.forward.app") {
                    openFullSwitchboard()
                }
                RailActionButtonView(title: "Open registry", symbol: "doc.text.magnifyingglass") {
                    revealSwitchboardRegistry()
                }
            }
        }
    }

    private var bottomModuleDock: some View {
        HStack(spacing: 8) {
            DockActionButton(title: "Chat", symbol: "bubble.left.and.text.bubble.right.fill", module: .chat, activeModule: $activeModule)
            DockActionButton(title: "Dashboard", symbol: "square.grid.2x2", module: .home, activeModule: $activeModule)
            DockActionButton(title: "Notes", symbol: "note.text", module: .notes, activeModule: $activeModule)
            DockActionButton(title: "Shelf", symbol: state.shelfBatches.isEmpty ? "tray" : "tray.full.fill", module: .shelf, activeModule: $activeModule)
            DockActionButton(title: "Media", symbol: "music.note", module: .music, activeModule: $activeModule)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.16), in: Capsule())
    }

    private func homeContent(stretch: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                homeSectionHeader(symbol: "waveform.circle.fill", title: "Desk Agent", trailing: liveReadiness?.isReady == true ? "ready" : nil)

                liveBridgeStatusRow

                if shouldShowLiveVoicePulse {
                    liveVoicePulseRow
                } else if shouldShowBridgePhoneActivity {
                    bridgePhoneActivityRow
                } else {
                    homeStatusPill(symbol: "message.fill", title: "Hermes", detail: homeHermesDetail, tint: Color(red: 0.42, green: 0.76, blue: 1.0))
                }

                quickTogglesRow

                Spacer(minLength: 0)
            }
            .frame(width: 245, alignment: .topLeading)

            Divider()
                .frame(height: 210 + stretch)
                .overlay(Color.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 8) {
                homeSectionHeader(symbol: "server.rack", title: "Switchboard", trailing: switchboardStatusLabel)

                if switchboardServices.isEmpty {
                    Button {
                        revealSwitchboardRegistry()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                            Text("Add services in SERVICES.yaml")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white.opacity(0.56))
                        .frame(height: 28)
                        .padding(.horizontal, 9)
                        .background(Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
                    }
                    .buttonStyle(NotchPressButtonStyle())
                } else if filteredSwitchboardServices.isEmpty {
                    Text("No matching services.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(maxWidth: .infinity, minHeight: 148 + stretch, alignment: .center)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(filteredSwitchboardServices) { service in
                                switchboardRow(service)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 148 + stretch, maxHeight: 148 + stretch, alignment: .topLeading)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                    TextField("Search services...", text: $switchboardSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                    if !switchboardSearch.isEmpty {
                        Button {
                            switchboardSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.34))
                        }
                        .buttonStyle(.plain)
                        .help("Clear service search")
                    }
                    homeMiniButton(symbol: "arrow.clockwise", title: "Refresh services") {
                        refreshSwitchboardHealth()
                    }
                    homeMiniButton(symbol: "arrow.up.forward.app", title: "Open Switchboard") {
                        openFullSwitchboard()
                    }
                }
                .frame(height: 24)
                .padding(.leading, 8)
                .padding(.trailing, 3)
                .background(Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))

                Spacer(minLength: 0)
            }
            .frame(width: 330, alignment: .topLeading)

            Divider()
                .frame(height: 210 + stretch)
                .overlay(Color.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 8) {
                homeSectionHeader(symbol: "checklist", title: "Reminders", trailing: reminders.statusBadge)

                VStack(alignment: .leading, spacing: 6) {
                    remindersSummaryPill

                    if reminders.items.isEmpty {
                        Text(reminders.emptyMessage)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(maxWidth: .infinity, minHeight: 48 + stretch * 0.35, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                            .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.035), lineWidth: 1))
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(reminders.items) { reminder in
                                    reminderRow(reminder)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48 + stretch * 0.35, maxHeight: 48 + stretch * 0.35, alignment: .topLeading)
                    }

                    HStack(spacing: 6) {
                        homeMiniButton(symbol: "arrow.clockwise", title: "Refresh reminders") {
                            reminders.load()
                        }
                        homeMiniButton(symbol: "arrow.up.forward.app", title: "Open Apple Reminders") {
                            openAppleReminders()
                        }
                        Spacer(minLength: 0)
                    }
                }

                Divider().overlay(Color.white.opacity(0.07))

                homeSectionHeader(symbol: "calendar", title: "Calendar", trailing: calendarAgenda.statusBadge)

                VStack(alignment: .leading, spacing: 6) {
                    calendarSummaryPill

                    if calendarAgenda.items.isEmpty {
                        Text(calendarAgenda.emptyMessage)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(maxWidth: .infinity, minHeight: 40 + stretch * 0.3, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                            .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.035), lineWidth: 1))
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(calendarAgenda.items) { item in
                                    calendarEventRow(item)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40 + stretch * 0.3, maxHeight: 40 + stretch * 0.3, alignment: .topLeading)
                    }

                    HStack(spacing: 6) {
                        homeMiniButton(symbol: "arrow.clockwise", title: "Refresh calendar") {
                            calendarAgenda.load()
                        }
                        homeMiniButton(symbol: "arrow.up.forward.app", title: "Open Apple Calendar") {
                            openAppleCalendar()
                        }
                        Spacer(minLength: 0)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 180, alignment: .topLeading)
        }
        .padding(.horizontal, 4)
        .frame(height: 246 + stretch, alignment: .center)
    }

    private var remindersSummaryPill: some View {
        homeStatusPill(
            symbol: reminders.statusSymbol,
            title: reminders.statusTitle,
            detail: reminders.statusDetail,
            tint: reminders.tintColor
        )
    }

    private var calendarSummaryPill: some View {
        homeStatusPill(
            symbol: calendarAgenda.statusSymbol,
            title: calendarAgenda.statusTitle,
            detail: calendarAgenda.statusDetail,
            tint: calendarAgenda.tintColor
        )
    }

    private func reminderRow(_ reminder: NotchReminderItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: reminder.isOverdue ? "exclamationmark.circle.fill" : "circle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(reminder.isOverdue ? Color(red: 1.0, green: 0.42, blue: 0.38) : .white.opacity(0.36))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(reminder.subtitle)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(reminder.isOverdue ? 0.046 : 0.028), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        .help(reminder.subtitle)
    }

    private func calendarEventRow(_ item: NotchCalendarItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.isNow ? "calendar.badge.clock" : "calendar")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(item.isNow ? Color(red: 0.32, green: 0.9, blue: 0.62) : item.tint.opacity(0.9))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(item.isNow ? 0.046 : 0.028), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        .help(item.subtitle)
    }

    private var homeHermesDetail: String {
        if isSendingToHermes {
            return hermesThinkingLabel
        }
        if let latest = chatMessages.last(where: { $0.role != .system }) {
            return latest.role == .user ? "Last asked: \(latest.text)" : "Last reply: \(latest.text)"
        }
        return "Ready for chat"
    }

    private func homeSectionHeader(symbol: String, title: String, trailing: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white.opacity(0.72))
    }

    private func homeStatusPill(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(0.055), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.028), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
    }

    private func homeMiniButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white.opacity(0.66))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(0.052), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
    }

    private func homeRouteButton(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.052), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.032), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(detail)
    }

    private var quickTogglesRow: some View {
        HStack(spacing: 6) {
            ToggleIconButton(symbol: state.notchListeningEnabled ? "waveform.circle.fill" : "waveform.circle", title: "Voice Listening", isActive: state.notchListeningEnabled) {
                toggleNotchListening()
            }
            ToggleIconButton(symbol: isDndActive ? "moon.fill" : "moon", title: "Do Not Disturb", isActive: isDndActive) {
                toggleDND()
            }
            ToggleIconButton(symbol: "doc.text.magnifyingglass", title: "Notes module", isActive: activeModule == .notes) {
                activeModule = .notes
            }
            ToggleIconButton(symbol: "server.rack", title: "Switchboard module", isActive: activeModule == .switchboard) {
                activeModule = .switchboard
            }
            ToggleIconButton(symbol: isLampActive ? "lightbulb.fill" : "lightbulb", title: "Lamp toggle", isActive: isLampActive) {
                toggleLamp()
            }
            ToggleIconButton(symbol: "lock.fill", title: "Lock screen", isActive: false) {
                lockScreen()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.055), lineWidth: 1))
    }

    private var screenTimeChart: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 3.5)
            Circle()
                .trim(from: 0.0, to: 0.65)
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.75, green: 0.48, blue: 1.0), Color(red: 0.34, green: 0.68, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            
            VStack(spacing: 0) {
                Text("10m")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Today")
                    .font(.system(size: 5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .frame(width: 32, height: 32)
    }

    private var launcherAppsRow: some View {
        HStack(spacing: -8) {
            LauncherIconView(name: "Finder", symbol: "face.smiling") {
                launchApp(name: "Finder")
            }
            LauncherIconView(name: "Discord", symbol: "bubble.left.and.bubble.right.fill") {
                launchApp(name: "Discord")
            }
            LauncherIconView(name: "Safari", symbol: "safari.fill") {
                launchApp(name: "Safari")
            }
            LauncherIconView(name: "Spotify", symbol: "music.note") {
                launchApp(name: "Spotify")
            }
        }
    }

    private struct ToggleIconButton: View {
        let symbol: String
        let title: String
        let isActive: Bool
        let action: () -> Void
        
        @State private var isHovering = false
        @State private var clickScale: CGFloat = 1.0
        @State private var clickRotation: Double = 0.0
        
        var body: some View {
            Button(action: {
                action()
                clickScale = 1.25
                clickRotation = 12.0
                withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) {
                    clickScale = 1.0
                    clickRotation = 0.0
                }
            }) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? Color.black.opacity(0.85) : (isHovering ? Color.white : Color.white.opacity(0.68)))
                    .frame(width: 18, height: 18)
                    .background(
                        isActive ? Color.white : (isHovering ? Color.white.opacity(0.16) : Color.white.opacity(0.065)),
                        in: Circle()
                    )
                    .scaleEffect(isHovering ? 1.08 : 1.0)
                    .scaleEffect(clickScale)
                    .rotationEffect(.degrees(clickRotation))
            }
            .buttonStyle(.plain)
            .help(title)
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
        }
    }

    private struct ScreenTimeRow: View {
        let name: String
        let time: String
        let color: Color
        var body: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                Text(name)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(time)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .frame(height: 10)
        }
    }

    private struct LauncherIconView: View {
        let name: String
        let symbol: String
        let action: () -> Void
        
        @State private var isHovering = false
        
        var body: some View {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.18), Color(white: 0.11)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.34, green: 0.68, blue: 1.0), Color(red: 0.75, green: 0.48, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.2 : 1.0)
                .offset(y: isHovering ? -4 : 0)
                .shadow(color: Color.black.opacity(0.35), radius: isHovering ? 5 : 2, y: isHovering ? 3 : 1)
            }
            .buttonStyle(.plain)
            .help("Open \(name)")
            .onHover { hovering in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                    isHovering = hovering
                }
            }
        }
    }

    private struct ActionIconView: View {
        let name: String
        let symbol: String
        let action: () -> Void
        
        @State private var isHovering = false
        
        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? .white : .white.opacity(0.72))
                    .frame(width: 24, height: 24)
                    .background(
                        isHovering ? Color.white.opacity(0.14) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovering ? 0.2 : 0.07), lineWidth: 1)
                    )
                    .scaleEffect(isHovering ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .help(name)
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                    isHovering = hovering
                }
            }
        }
    }

    private func toggleDND() {
        isDndActive.toggle()
        state.statusMessage = isDndActive ? "Do Not Disturb turned ON" : "Do Not Disturb turned OFF"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"D\" using {control down, shift down, option down, command down}"]
        try? process.run()
    }

    private func lockScreen() {
        state.statusMessage = "Locking screen..."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    private func toggleLamp() {
        isLampActive.toggle()
        state.statusMessage = isLampActive ? "Lamp Mode ON (Screen Brightness High)" : "Lamp Mode OFF"
    }

    private func launchApp(name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        try? process.run()
        state.statusMessage = "Launching \(name)..."
    }

    private func openAppleReminders() {
        launchApp(name: "Reminders")
        state.statusMessage = "Opening Apple Reminders."
    }

    private func openAppleCalendar() {
        launchApp(name: "Calendar")
        state.statusMessage = "Opening Apple Calendar."
    }

    private func openHermesSkillsReference() {
        if let path = DeskAgentLocalPaths.skillsReferencePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            state.statusMessage = "Opening Hermes skills reference."
        } else {
            state.statusMessage = "No skills reference file found."
        }
    }

    private func shelfContent(stretch: CGFloat) -> some View {
        Group {
            if state.shelfBatches.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(state.shelfBatches.enumerated()), id: \.element.id) { index, batch in
                            batchCard(batch, accent: batchAccent(index))
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(height: 98 + stretch)
    }

    private func chatPeek(stretch: CGFloat) -> some View {
        VStack(spacing: chatFocusMode ? 7 : 6) {
            liveBridgeStatusRow
            if shouldShowLiveVoicePulse {
                liveVoicePulseRow
            }
            if shouldShowBridgePhoneActivity {
                bridgePhoneActivityRow
            }

            chatSessionMemoryRow

            if camera.isRunning || camera.authorizationDenied {
                HStack(spacing: 8) {
                    ZStack {
                        if camera.isRunning {
                            NotchCameraPreview(session: camera.session)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.055))
                                .overlay {
                                    Image(systemName: "video.slash")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                        }
                    }
                    .frame(width: 78, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(camera.isRunning ? 0.14 : 0.06), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(cameraStatusTitle)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                        Text(cameraStatusSubtitle)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(chatMessages.suffix(chatVisibleMessageLimit)) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                        if isSendingToHermes {
                            typingBubble
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: chatFeedHeight + stretch,
                    maxHeight: chatFeedHeight + stretch,
                    alignment: .bottom
                )
                .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
                )
                .onChange(of: chatMessages.count) { _ in
                    scrollToLatestChatMessage(proxy, animated: true)
                }
                .onChange(of: isSendingToHermes) { _ in
                    DispatchQueue.main.async {
                        scrollToLatestChatMessage(proxy, animated: true)
                    }
                }
                .onAppear {
                    scrollToLatestChatMessage(proxy, animated: false)
                    DispatchQueue.main.async {
                        scrollToLatestChatMessage(proxy, animated: false)
                    }
                }
                .onChange(of: expanded) { isExpanded in
                    guard isExpanded, activeModule == .chat else { return }
                    DispatchQueue.main.async {
                        scrollToLatestChatMessage(proxy, animated: false)
                    }
                }
                .onChange(of: activeModule) { module in
                    guard module == .chat, expanded else { return }
                    DispatchQueue.main.async {
                        scrollToLatestChatMessage(proxy, animated: false)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    openChatAttachmentPicker()
                } label: {
                    Image(systemName: chatPendingAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(chatPendingAttachments.isEmpty ? .white.opacity(0.76) : Color.black.opacity(0.82))
                        .frame(width: 24, height: 24)
                        .background(chatPendingAttachments.isEmpty ? Color.white.opacity(0.065) : Color(red: 0.42, green: 0.92, blue: 0.78), in: Circle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .help(chatPendingAttachments.isEmpty ? "Attach files or folders" : "\(chatPendingAttachments.count) attached")

                Button {
                    attachLatestShelfImageToChat()
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.065), in: Circle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .help("Attach latest capture")

                Button {
                    attachClipboardToChat()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.065), in: Circle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .help("Add clipboard to chat")

                Button {
                    camera.toggle()
                } label: {
                    Image(systemName: camera.isRunning ? "video.fill" : "video")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(camera.isRunning ? Color.black.opacity(0.82) : .white.opacity(0.76))
                        .frame(width: 24, height: 24)
                        .background(camera.isRunning ? Color(red: 0.42, green: 0.92, blue: 0.78) : Color.white.opacity(0.065), in: Circle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .help(camera.isRunning ? "Stop webcam" : "Share webcam")

                TextField("Message Hermes...", text: $chatDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(height: 28)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.075), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
                    .disabled(isSendingToHermes)
                    .onSubmit {
                        submitChatPeek()
                    }

                Button {
                    submitChatPeek()
                } label: {
                    let canSend = !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chatPendingAttachments.isEmpty
                    Image(systemName: chatSubmitSymbol)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(canSend ? Color.black.opacity(0.84) : .white.opacity(0.76))
                        .frame(width: 24, height: 24)
                        .background(
                            canSend ? Color(red: 0.34, green: 0.68, blue: 1.0) : Color.white.opacity(0.065),
                            in: Circle()
                        )
                }
                .buttonStyle(NotchPressButtonStyle())
                .help(chatSubmitHelp)
                .disabled((chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chatPendingAttachments.isEmpty) || isSendingToHermes)
            }

            if !chatPendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chatPendingAttachments) { attachment in
                            pendingAttachmentPill(attachment) {
                                removePendingAttachment(attachment)
                            }
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.58))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
            }
        }
        .frame(height: (chatFocusMode ? 282 : 246) + stretch, alignment: .top)
        .onDrop(of: Self.chatDropTypes, isTargeted: nil) { providers in
            handleChatDrop(providers)
        }
    }

    private var chatFeedHeight: CGFloat {
        let phoneActivityOffset: CGFloat = shouldShowBridgePhoneActivity ? 26 : 0
        let memoryRowOffset: CGFloat = 22
        if camera.isRunning || camera.authorizationDenied {
            let base: CGFloat = shouldShowLiveVoicePulse ? (chatFocusMode ? 260 : 244) : (chatFocusMode ? 278 : 252)
            return max(16, base - phoneActivityOffset - memoryRowOffset)
        }
        let base: CGFloat = shouldShowLiveVoicePulse ? (chatFocusMode ? 298 : 262) : (chatFocusMode ? 318 : 282)
        return max(18, base - phoneActivityOffset - memoryRowOffset)
    }

    private var chatVisibleMessageLimit: Int {
        if camera.isRunning || camera.authorizationDenied {
            return chatFocusMode ? 22 : 16
        }
        return chatFocusMode ? 30 : 24
    }

    private var chatSessionMemoryRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(red: 0.62, green: 0.82, blue: 1.0))
            Text(chatSessionMemorySummary)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !hermesSessionId.isEmpty {
                Text("session \(shortHermesSessionId)")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.white.opacity(0.026), in: Capsule())
        .help("The Notch keeps a light visible transcript. Hermes keeps deeper continuity through the session id.")
    }

    private var chatSessionMemorySummary: String {
        let visible = min(chatMessages.count, maxPersistedChatMessages)
        if hermesSessionId.isEmpty {
            return "Visible chat is local; new Hermes session"
        }
        return "Visible last \(visible); Hermes keeps deeper context"
    }

    private var shortHermesSessionId: String {
        let trimmed = hermesSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "new" }
        return String(trimmed.prefix(8))
    }

    private func scrollToLatestChatMessage(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = chatMessages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var typingBubble: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.58)
            Text(hermesThinkingLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(activePulse ? 0.72 : 0.32))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            Color.white.opacity(activePulse ? 0.055 : 0.025),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    Color(red: 0.34, green: 0.68, blue: 1.0).opacity(activePulse ? 0.42 : 0.12),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color(red: 0.34, green: 0.68, blue: 1.0).opacity(activePulse ? 0.25 : 0.0),
            radius: activePulse ? 6 : 0
        )
    }

    private var liveBridgeStatusRow: some View {
        HStack(spacing: 7) {
            agentHealthDot(title: "Hermes", color: hermesHealthColor)
            agentHealthDot(title: "Live", color: liveBridgeStatusColor)
            agentHealthDot(title: "Phone", color: phoneBridgeHealthColor)

            Text(agentHealthSummaryText)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)

            Spacer(minLength: 0)

            if isCheckingLiveReadiness {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        .onTapGesture {
            mountLiveVoiceBridgeIfNeeded()
            if !liveVoice.pageReady {
                liveVoice.reloadBridge()
            }
            refreshLiveReadiness()
        }
        .help(liveBridgeHelpText)
    }

    private func agentHealthDot(title: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
    }

    private var hermesHealthColor: Color {
        isSendingToHermes
            ? Color(red: 0.62, green: 0.82, blue: 1.0)
            : Color(red: 0.32, green: 0.9, blue: 0.62)
    }

    private var phoneBridgeHealthColor: Color {
        if phoneLiveVoiceActive {
            return Color(red: 0.32, green: 0.9, blue: 0.62)
        }
        if (notchBridgeStatus?.pairedDevices ?? 0) > 0 {
            return .white.opacity(0.34)
        }
        if !liveReadinessError.isEmpty {
            return .orange
        }
        return .white.opacity(0.3)
    }

    private var agentHealthSummaryText: String {
        if isSendingToHermes {
            return "Hermes answering"
        }
        if isChangingLiveSession || liveVoice.isActive || phoneLiveVoiceActive {
            return notchBridgeSummaryText
        }
        if !liveReadinessError.isEmpty {
            return "Hermes text ready; Live/phone helper offline"
        }
        if liveReadiness?.isReady == true {
            return (notchBridgeStatus?.pairedDevices ?? 0) > 0 ? "Hermes, Live ready; phone remembered" : "Hermes and Live ready"
        }
        if isCheckingLiveReadiness {
            return "Checking Live and phone helper"
        }
        return "Hermes text ready; helper check pending"
    }

    private var notchBridgeSummaryText: String {
        if let notchBridgeStatus {
            if let activeSession = notchBridgeStatus.activeLiveSessions.first {
                if activeSession.source == "iphone" {
                    return phoneLiveVoiceStateTitle(phoneSessionState)
                }
                if activeSession.source == "notch" {
                    return localLiveVoiceStateTitle(liveVoice.liveState)
                }
                if let latestTurn = notchBridgeStatus.recentConversationTurns.first,
                   latestTurn.source == "iphone",
                   latestTurn.conversationId == activeSession.conversationId {
                    return "phone joined"
                }
                return notchBridgeStatus.activeLiveSessions.count == 1 ? "live session" : "\(notchBridgeStatus.activeLiveSessions.count) live sessions"
            }
            if !notchBridgeStatus.airSends.isEmpty {
                return notchBridgeStatus.airSends.count == 1 ? "AirSend waiting" : "\(notchBridgeStatus.airSends.count) AirSends"
            }
            if notchBridgeStatus.pendingApprovals > 0 {
                return "\(notchBridgeStatus.pendingApprovals) review\(notchBridgeStatus.pendingApprovals == 1 ? "" : "s")"
            }
            if let latestTurn = notchBridgeStatus.recentConversationTurns.first, latestTurn.source == "iphone" {
                return latestTurn.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "phone heard" : "phone replied"
            }
            if notchBridgeStatus.pairedDevices > 0 {
                return "phone remembered"
            }
            return notchBridgeStatus.compactStatus
        }
        return "bridge ready"
    }

    private var chatSubmitSymbol: String {
        return "arrow.up"
    }

    private var chatSubmitHelp: String {
        let trimmed = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || !chatPendingAttachments.isEmpty {
            return "Send to Hermes"
        }
        return "Type a message to send. Use the Notch voice button to talk."
    }

    private var shouldShowLiveVoicePulse: Bool {
        liveVoice.isActive
            || liveVoice.liveState == "blocked"
            || liveVoice.liveState == "offline"
            || !liveVoice.sessionId.isEmpty
            || !liveVoice.lastUserTranscript.isEmpty
            || !liveVoice.lastAssistantTranscript.isEmpty
            || phoneLiveVoiceActive
    }

    private var activePhoneLiveSession: DeskAgentActiveLiveSession? {
        notchBridgeStatus?.activeLiveSessions.first { $0.source == "iphone" }
    }

    private var latestPhoneBridgeTurn: DeskAgentConversationTurn? {
        notchBridgeStatus?.recentConversationTurns.first { $0.source == "iphone" }
    }

    private var shouldShowBridgePhoneActivity: Bool {
        activePhoneLiveSession != nil || latestPhoneBridgeTurn != nil
    }

    private var bridgePhoneActivityRow: some View {
        HStack(spacing: 7) {
            Image(systemName: activePhoneLiveSession == nil ? "iphone" : "iphone.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(phoneActivityColor)
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(0.055), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(phoneActivityTitle)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(phoneActivityDetail)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.028), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .help(phoneActivityHelpText)
    }

    private var phoneActivityTitle: String {
        activePhoneLiveSession == nil ? "Phone replied" : "Phone live"
    }

    private var phoneActivityDetail: String {
        if activePhoneLiveSession != nil {
            if let turn = latestPhoneBridgeTurn, turn.conversationId == activePhoneLiveSession?.conversationId {
                return phoneTurnPreview(turn)
            }
            return "Listening from iPhone"
        }
        if let turn = latestPhoneBridgeTurn {
            return phoneTurnPreview(turn)
        }
        return "Waiting for phone"
    }

    private var phoneActivityColor: Color {
        activePhoneLiveSession == nil
            ? Color(red: 0.42, green: 0.76, blue: 1.0)
            : Color(red: 0.32, green: 0.9, blue: 0.62)
    }

    private var phoneActivityHelpText: String {
        if activePhoneLiveSession != nil {
            return "The phone is using the shared Desk Agent session."
        }
        return "Latest phone reply imported through the Desk Agent bridge."
    }

    private func phoneTurnPreview(_ turn: DeskAgentConversationTurn) -> String {
        let response = turn.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !response.isEmpty {
            return "Replied: \(response)"
        }
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return "Heard: \(text)"
        }
        return "Phone reply imported"
    }

    private var liveVoicePulseRow: some View {
        let isLiveActive = liveVoice.isActive || state.notchListeningEnabled || phoneLiveVoiceActive
        return HStack(spacing: 7) {
            ZStack {
                if isLiveActive {
                    // Outer wave
                    Circle()
                        .stroke(liveBridgeStatusColor, lineWidth: 1)
                        .scaleEffect(activePulse ? 2.2 : 1.0)
                        .opacity(activePulse ? 0.0 : 0.7)
                        .frame(width: 16, height: 16)
                    
                    // Inner wave
                    Circle()
                        .stroke(liveBridgeStatusColor, lineWidth: 1.5)
                        .scaleEffect(activePulse ? 1.6 : 1.0)
                        .opacity(activePulse ? 0.0 : 0.85)
                        .frame(width: 16, height: 16)
                }
                
                Image(systemName: liveVoicePulseSymbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(isLiveActive ? Color.black.opacity(0.85) : liveBridgeStatusColor)
                    .frame(width: 16, height: 16)
                    .background(isLiveActive ? liveBridgeStatusColor : Color.white.opacity(0.055), in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(liveVoiceStateTitle)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(liveVoiceDetailText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.028), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .applyHueRotationPhaseAnimator(active: isLiveActive)
    }

    private var latestAirSend: DeskAgentAirSend? {
        notchBridgeStatus?.airSends.first
    }

    private var liveBridgeStatusTitle: String {
        if isChangingLiveSession {
            return state.notchListeningEnabled || liveVoice.isActive ? "Stopping live voice" : "Starting live voice"
        }
        if let notchBridgeStatus, !notchBridgeStatus.airSends.isEmpty {
            return "AirSend waiting"
        }
        if liveVoice.isActive || liveVoice.liveState == "blocked" || liveVoice.liveState == "offline" {
            return liveVoiceStateTitle
        }
        if let activeSession = notchBridgeStatus?.activeLiveSessions.first {
            if activeSession.source == "iphone" {
                return phoneLiveVoiceStateTitle(phoneSessionState)
            }
            if activeSession.source == "notch" {
                return localLiveVoiceStateTitle(liveVoice.liveState)
            }
            return "Live session active"
        }
        if liveReadiness?.isReady == true && !liveVoice.pageReady {
            return "Live shell loading"
        }
        if let liveReadiness {
            return liveReadiness.compactStatus
        }
        if isCheckingLiveReadiness {
            return "Checking helper..."
        }
        if !liveReadinessError.isEmpty {
            return "Live helper offline"
        }
        return "Helper check pending"
    }

    private var liveBridgeStatusColor: Color {
        if liveVoice.isActive {
            return localLiveVoiceColor(liveVoice.liveState)
        }
        if phoneLiveVoiceActive {
            return localLiveVoiceColor(phoneSessionState)
        }
        if liveVoice.liveState == "blocked" || liveVoice.liveState == "offline" {
            return .orange
        }
        if liveReadiness?.isReady == true && !liveVoice.pageReady {
            return Color(red: 0.34, green: 0.68, blue: 1.0)
        }
        if let liveReadiness {
            if liveReadiness.isReady {
                return Color(red: 0.32, green: 0.9, blue: 0.62)
            }
            return liveReadiness.level == "blocked" ? .orange : .red
        }
        return isCheckingLiveReadiness ? Color(red: 0.34, green: 0.68, blue: 1.0) : .white.opacity(0.34)
    }

    private func localLiveVoiceColor(_ state: String) -> Color {
        switch state {
        case "thinking":
            return Color(red: 1.0, green: 0.78, blue: 0.36)
        case "replying":
            return Color(red: 0.42, green: 0.76, blue: 1.0)
        default:
            return Color(red: 0.32, green: 0.9, blue: 0.62)
        }
    }

    private var liveBridgeHelpText: String {
        if isChangingLiveSession {
            return "Live voice session is changing state."
        }
        if !liveVoice.warning.isEmpty {
            return liveVoice.warning
        }
        if liveReadiness?.isReady == true && !liveVoice.pageReady {
            return "Desk Agent is ready, but live voice is still loading. Tap to reload and refresh status."
        }
        if let activeSession = notchBridgeStatus?.activeLiveSessions.first {
            switch activeSession.source {
            case "iphone":
                return "The phone is running the shared Desk Agent session."
            case "notch":
                return "The Notch is running the shared Desk Agent session."
            default:
                return "A shared Desk Agent session is active."
            }
        }
        if let liveReadiness {
            return liveReadiness.nextStep
        }
        if liveReadinessError.isEmpty {
            return "Hermes text runs locally. Tap to check Live voice and phone helper readiness."
        }
        return "Hermes text still works. Live voice, phone pairing, and AirSend need the helper: \(liveReadinessError)"
    }

    private var liveVoicePulseSymbol: String {
        let state = liveVoice.isActive ? liveVoice.liveState : phoneSessionState
        switch state {
        case "connecting":
            return "dot.radiowaves.left.and.right"
        case "listening":
            return "waveform"
        case "thinking":
            return "brain.head.profile"
        case "replying":
            return "speaker.wave.2.fill"
        case "blocked", "offline":
            return "exclamationmark.triangle.fill"
        default:
            return "waveform.circle"
        }
    }

    private var liveVoiceStateTitle: String {
        if liveVoice.isActive {
            return localLiveVoiceStateTitle(liveVoice.liveState)
        }
        if phoneLiveVoiceActive {
            return phoneLiveVoiceStateTitle(phoneSessionState)
        }
        return "Live voice ready"
    }

    private func localLiveVoiceStateTitle(_ liveState: String) -> String {
        switch liveState {
        case "connecting": return "Connecting live voice"
        case "listening": return "Listening"
        case "thinking": return "Thinking"
        case "replying": return "Replying"
        case "learn": return "Learning"
        case "blocked": return "Live voice blocked"
        case "offline": return "Live helper offline"
        default: return state.notchListeningEnabled ? "Live voice active" : "Live voice ready"
        }
    }

    private func phoneLiveVoiceStateTitle(_ liveState: String) -> String {
        switch liveState {
        case "connecting": return "Phone: connecting..."
        case "listening": return "Phone: listening"
        case "thinking": return "Phone: working..."
        case "replying": return "Phone: replying"
        case "stopped": return "Phone: stopped"
        default: return "Phone: live session"
        }
    }

    private var liveVoiceDetailText: String {
        if liveVoice.isActive {
            if !liveVoice.warning.isEmpty {
                return liveVoice.warning
            }
            if !liveVoice.lastFinalAssistantTranscript.isEmpty {
                return "Replied: \(liveVoice.lastFinalAssistantTranscript)"
            }
            if !liveVoice.lastAssistantTranscript.isEmpty {
                return "Replying: \(liveVoice.lastAssistantTranscript)"
            }
            if !liveVoice.lastFinalUserTranscript.isEmpty {
                return "Heard: \(liveVoice.lastFinalUserTranscript)"
            }
            if !liveVoice.lastUserTranscript.isEmpty {
                return "Hearing: \(liveVoice.lastUserTranscript)"
            }
            if let liveReadiness {
                return liveReadiness.isReady ? "Ready for live voice" : liveReadiness.compactStatus
            }
            return liveVoice.pageReady ? "Ready for live voice" : "Loading live voice"
        } else if let session = activePhoneSession {
            if let diagnostic = session.lastDiagnostic {
                return diagnostic.detail
            }
            return "Active live session on phone"
        }
        return "Live voice ready"
    }

    private var hermesThinkingLabel: String {
        if hermesElapsedSeconds >= 15 {
            return "Still working... \(hermesElapsedSeconds)s"
        }
        if hermesElapsedSeconds > 0 {
            return "Hermes is thinking... \(hermesElapsedSeconds)s"
        }
        return "Hermes is thinking..."
    }

    private func chatBubble(_ message: NotchChatMessage) -> some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 46)
            }

            VStack(alignment: .leading, spacing: 5) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(message.role == .user ? Color.black.opacity(0.82) : .white.opacity(0.72))
                        .lineLimit(message.attachments.isEmpty ? 4 : 2)
                        .multilineTextAlignment(.leading)
                }

                if let source = message.source, !source.isEmpty {
                    let isPhone = (source == "iphone" || source == "phone")
                    let isLive = (source == "live" || source == "voice")
                    HStack(spacing: 3) {
                        Image(systemName: isPhone ? "iphone" : (isLive ? "waveform.circle.fill" : "waveform"))
                            .font(.system(size: 7, weight: .bold))
                        Text(source == "iphone" ? "phone" : source)
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(
                        message.role == .user 
                            ? (isPhone ? Color(red: 0.1, green: 0.6, blue: 0.3) : (isLive ? Color(red: 0.0, green: 0.45, blue: 0.75) : Color.black.opacity(0.4)))
                            : (isPhone ? Color(red: 0.32, green: 0.9, blue: 0.62) : (isLive ? Color(red: 0.34, green: 0.68, blue: 1.0) : Color.white.opacity(0.45)))
                    )
                }

                ForEach(message.attachments) { attachment in
                    chatAttachmentPreview(attachment)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: 310, alignment: .leading)
            .background(chatBubbleFill(message.role), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(message.role == .user ? 0.08 : 0.045), lineWidth: 1)
            )

            if message.role != .user {
                Spacer(minLength: 46)
            }
        }
    }

    private func chatBubbleFill(_ role: NotchChatRole) -> Color {
        switch role {
        case .user:
            return Color.white.opacity(0.86)
        case .assistant:
            return Color.white.opacity(0.07)
        case .system:
            return Color.white.opacity(0.035)
        }
    }

    private func chatAttachmentPreview(_ attachment: NotchChatAttachment) -> some View {
        Button {
            if attachment.kind == .localImage {
                state.previewLocalFile(attachment.url, title: attachment.title)
            } else {
                NSWorkspace.shared.open(attachment.url)
                state.statusMessage = "Opening \(attachment.title)."
            }
        } label: {
            Group {
                switch attachment.kind {
                case .localImage:
                    if let image = NSImage(contentsOf: attachment.url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 116, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        attachmentChip(attachment)
                    }
                case .remoteImage:
                    AsyncImage(url: attachment.url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 116, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        default:
                            attachmentChip(attachment)
                        }
                    }
                case .localVideo, .localFile, .localFolder, .remoteFile:
                    attachmentChip(attachment)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(attachment.kind == .localImage ? "Preview \(attachment.title)" : "Open \(attachment.title)")
    }

    private func attachmentChip(_ attachment: NotchChatAttachment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 10, weight: .bold))
            Text(attachment.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.64))
        .frame(width: 116, height: 26)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pendingAttachmentPill(_ attachment: NotchChatAttachment, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(attachment.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.58))
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.white.opacity(0.035), in: Capsule())
    }

    private func notesContent(stretch: CGFloat) -> some View {
        HStack(spacing: 12) {
            // Left Format Panel
            if !quickNoteFocusMode {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        FormatIconButton(label: "Bold", symbol: "bold") {
                            insertMarkdown("**Bold**")
                        }
                        FormatIconButton(label: "Italic", symbol: "italic") {
                            insertMarkdown("*Italic*")
                        }
                    }
                    
                    HStack(spacing: 8) {
                        FormatIconButton(label: "Strike", symbol: "strikethrough") {
                            insertMarkdown("~~Strike~~")
                        }
                        FormatIconButton(label: "Code", symbol: "code") {
                            insertMarkdown("`Code`")
                        }
                    }
                    
                    HStack(spacing: 8) {
                        FormatIconButton(label: "List", symbol: "list.bullet") {
                            insertMarkdown("\n- ")
                        }
                        FormatIconButton(label: "Number", symbol: "list.number") {
                            insertMarkdown("\n1. ")
                        }
                    }
                    
                    HStack(spacing: 8) {
                        FormatIconButton(label: "Heading", symbol: "textformat.size") {
                            insertMarkdown("\n## ")
                        }
                        FormatIconButton(label: "Quote", symbol: "text.quote") {
                            insertMarkdown("\n> ")
                        }
                    }
                }
                .frame(width: 124, alignment: .leading)
                
                Divider()
                    .frame(height: 204 + stretch)
                    .overlay(Color.white.opacity(0.07))
            }
            
            // Right Text Editor Card
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $quickNoteDraft)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
                    )
                
                if quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Jot a quick note for Obsidian...")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                
                // Bottom Right Resize Arrow
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 232 + stretch)
    }

    private struct FormatIconButton: View {
        let label: String
        let symbol: String
        let action: () -> Void
        
        @State private var isHovering = false
        @State private var clickScale: CGFloat = 1.0
        @State private var clickRotation: Double = 0.0
        
        var body: some View {
            Button(action: {
                action()
                clickScale = 1.22
                clickRotation = 10.0
                withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) {
                    clickScale = 1.0
                    clickRotation = 0.0
                }
            }) {
                VStack(spacing: 3) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isHovering ? .white : .white.opacity(0.78))
                        .frame(width: 32, height: 32)
                        .background(
                            isHovering ? Color.white.opacity(0.14) : Color.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(isHovering ? 0.2 : 0.08), lineWidth: 1)
                        )
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .frame(width: 58, height: 52)
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(clickScale)
                .rotationEffect(.degrees(clickRotation))
            }
            .buttonStyle(.plain)
            .help("Format \(label)")
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                    isHovering = hovering
                }
            }
        }
    }

    private func insertMarkdown(_ text: String) {
        quickNoteDraft += text
        state.statusMessage = "Formatted with \(text)"
    }

    private func switchboardContent(stretch: CGFloat) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(switchboardHealthColor.opacity(0.18))
                        Circle()
                            .strokeBorder(switchboardHealthColor.opacity(0.42), lineWidth: 1)
                        Image(systemName: "server.rack")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(switchboardHealthColor.opacity(0.86))
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(switchboardHeadline)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        Text(switchboardSubheadline)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                    TextField("Search services...", text: $switchboardSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .frame(height: 22)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))

                Spacer(minLength: 0)
            }
            .frame(width: 230, alignment: .leading)

            Divider()
                .frame(height: 206 + stretch)
                .overlay(Color.white.opacity(0.08))

            if switchboardServices.isEmpty {
                Text("No services loaded.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filteredSwitchboardServices.isEmpty {
                Text("No matching services.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredSwitchboardServices.prefix(18)) { service in
                            switchboardRow(service)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, maxHeight: 220 + stretch, alignment: .topLeading)
            }
        }
        .frame(height: 246 + stretch)
    }

    private var filteredSwitchboardServices: [NotchSwitchboardService] {
        let trimmed = switchboardSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = switchboardServices.sorted { left, right in
            if left.priority != right.priority { return left.priority > right.priority }
            if left.favorite != right.favorite { return left.favorite && !right.favorite }
            if left.group != right.group { return left.group < right.group }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        guard !trimmed.isEmpty else { return services }
        return services.filter { $0.matches(trimmed) }
    }

    private var switchboardReachableCount: Int {
        switchboardReachability.values.filter { $0 }.count
    }

    private var switchboardCheckedCount: Int {
        switchboardReachability.count
    }

    private var switchboardStatusLabel: String? {
        guard !switchboardServices.isEmpty else { return nil }
        if isCheckingSwitchboard { return "Checking" }
        guard switchboardCheckedCount > 0 else { return "\(switchboardServices.count)" }
        return "\(switchboardReachableCount)/\(switchboardCheckedCount) up"
    }

    private var switchboardHeadline: String {
        if isCheckingSwitchboard {
            return "Checking services"
        }
        guard switchboardCheckedCount > 0 else {
            return "\(switchboardServices.count) services"
        }
        let down = max(0, switchboardCheckedCount - switchboardReachableCount)
        return down == 0 ? "All checked services up" : "\(down) down or unreachable"
    }

    private var switchboardSubheadline: String {
        if switchboardServices.isEmpty {
            return "Using SERVICES.yaml"
        }
        if let switchboardLastChecked {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Last checked \(formatter.string(from: switchboardLastChecked))"
        }
        return "Favorites first, search anything"
    }

    private var switchboardHealthColor: Color {
        if isCheckingSwitchboard {
            return Color(red: 0.34, green: 0.68, blue: 1.0)
        }
        guard switchboardCheckedCount > 0 else {
            return .white.opacity(0.5)
        }
        return switchboardReachableCount == switchboardCheckedCount
            ? Color(red: 0.32, green: 0.9, blue: 0.62)
            : Color(red: 1.0, green: 0.78, blue: 0.28)
    }

    private func switchboardRow(_ service: NotchSwitchboardService) -> some View {
        Button {
            openSwitchboardService(service)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(switchboardDotColor(service))
                    .frame(width: 6, height: 6)

                Image(systemName: service.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text("\(service.group) • \(service.status)")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: service.isFolder ? "folder" : "arrow.up.forward")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .frame(height: 24)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(service.favorite ? 0.052 : 0.032), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(service.targetLabel)
    }

    private func switchboardDotColor(_ service: NotchSwitchboardService) -> Color {
        guard let reachable = switchboardReachability[service.id] else {
            return .white.opacity(0.26)
        }
        return reachable ? Color(red: 0.32, green: 0.9, blue: 0.62) : Color(red: 1.0, green: 0.42, blue: 0.38)
    }

    private func musicContent(stretch: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                albumArtCover

                VStack(alignment: .leading, spacing: 3) {
                    Text(musicStatusTitle)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Text(musicStatusSubtitle)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    cycleMediaSource()
                } label: {
                    Text(mediaSource.rawValue.uppercased())
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                }
                .buttonStyle(NotchPressButtonStyle())
                .help("Switch player source")
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                musicProgressBar

                ZStack {
                    HStack(spacing: 3) {
                        ForEach(0..<28, id: \.self) { idx in
                            Capsule()
                                .fill(visualizerGradient)
                                .frame(width: 4, height: visualizerHeights[idx % visualizerHeights.count])
                        }
                    }
                    .frame(height: 28, alignment: .bottom)
                    .opacity(0.68)

                    HStack(spacing: 12) {
                        MusicMediaControlButton(symbol: "shuffle", title: "Shuffle", isPrimary: false) {
                            sendMediaControl(command: "shuffle")
                        }
                        MusicMediaControlButton(symbol: "backward.fill", title: "Previous", isPrimary: false) {
                            sendMediaControl(command: "previous track")
                        }
                        MusicMediaControlButton(symbol: state.notchPlaybackActive ? "pause.fill" : "play.fill", title: state.notchPlaybackActive ? "Pause" : "Play", isPrimary: true) {
                            sendMediaControl(command: "playpause")
                        }
                        MusicMediaControlButton(symbol: "forward.fill", title: "Next", isPrimary: false) {
                            sendMediaControl(command: "next track")
                        }
                        MusicMediaControlButton(symbol: "repeat", title: "Repeat", isPrimary: false) {
                            sendMediaControl(command: "repeat")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 72)
        .padding(.vertical, 22)
        .frame(height: 330 + stretch)
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard state.notchPlaybackActive else { return }
            visualizerPhase += 0.25
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                visualizerHeights = (0..<26).map { idx in
                    let wave1 = sin(visualizerPhase + Double(idx) * 0.45) * 11.0
                    let wave2 = cos(visualizerPhase * 0.75 - Double(idx) * 0.25) * 6.0
                    let randomNoise = Double.random(in: -1.5...2.0)
                    let height = 14.0 + wave1 + wave2 + randomNoise
                    return CGFloat(max(4.0, min(26.0, height)))
                }
            }
        }
    }

    private var musicProgressBar: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let fillWidth = proxy.size.width * musicProgressFraction
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.75, green: 0.48, blue: 1.0), Color(red: 0.34, green: 0.68, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, fillWidth - 4))
                        .shadow(color: .white.opacity(0.8), radius: 3)
                }
            }
            .frame(height: 4)

            HStack {
                Text(formatMusicTime(musicElapsedSeconds))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer()
                Text(musicDurationSeconds > 0 ? formatMusicTime(musicDurationSeconds) : "--:--")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
    }

    private func cycleMediaSource() {
        switch mediaSource {
        case .spotify:
            mediaSource = .plex
            externalNowPlayingTitle = ""
            externalNowPlayingSubtitle = "Browse Plex in the sidecar."
        case .plex, .music:
            mediaSource = .spotify
        }
        syncDisplayedPlaybackActive()
        loadMusicBrowserIfNeeded(for: mediaSource)
        refreshActiveMediaSourceStateForSource(mediaSource)
        state.statusMessage = "Active player source: \(mediaSource.rawValue.capitalized)"
    }

    private func loadMusicBrowserIfNeeded(for source: MediaSource, force: Bool = false) {
        guard source == .spotify || source == .plex else { return }
        guard let webView = state.musicWebView else { return }
        if !force, musicWebViewMatchesSource(webView, source: source) { return }
        guard let url = URL(string: musicBrowseWebURL(for: source)) else { return }
        webView.load(URLRequest(url: url))
    }

    private var currentSourcePlaybackActive: Bool {
        switch mediaSource {
        case .spotify:
            return spotifyPlaybackActive
        case .plex:
            return plexPlaybackActive
        case .music:
            return state.notchPlaybackActive
        }
    }

    private func syncDisplayedPlaybackActive() {
        guard mediaSource != .music else { return }
        let active = currentSourcePlaybackActive
        if state.notchPlaybackActive != active {
            state.notchPlaybackActive = active
        }
    }

    private func refreshActiveMediaSourceStateIfNeeded(now: Date) {
        switch mediaSource {
        case .spotify:
            guard now.timeIntervalSince(lastExternalMusicSyncAt) >= 2 else { return }
            lastExternalMusicSyncAt = now
            syncSpotifyPlaybackState()
        case .plex:
            guard musicWebViewMatchesSource(state.musicWebView, source: .plex),
                  now.timeIntervalSince(lastPlexProgressSyncAt) >= 1
            else { return }
            lastPlexProgressSyncAt = now
            syncWebPlayerProgress()
        case .music:
            break
        }
    }

    private func refreshActiveMediaSourceStateForSource(_ source: MediaSource) {
        switch source {
        case .spotify:
            syncSpotifyPlaybackState()
        case .plex:
            if musicWebViewMatchesSource(state.musicWebView, source: .plex) {
                syncWebPlayerProgress()
            }
        case .music:
            break
        }
    }

    private func sendMediaControl(command: String) {
        MarkShotLog.write("media control command=\(command) source=\(mediaSource.rawValue)")
        switch mediaSource {
        case .spotify:
            handleSpotifyMediaControl(command: command)
        case .plex:
            handlePlexMediaControl(command: command)
        case .music:
            if command == "playpause" {
                toggleMusicPlayback()
            } else if command == "next track" {
                playNextMusicTrack()
            } else if command == "previous track" {
                playPreviousMusicTrack()
            } else if command == "shuffle" {
                playRandomMusicTrack()
            } else if command == "repeat" {
                state.statusMessage = "Repeat is not wired for local music yet."
            }
        }
    }

    private func sendSpotifyControl(command: String) {
        let script = """
        if application "Spotify" is not running then
            return "stopped" & linefeed & "" & linefeed & "Spotify app is not running." & linefeed & "0" & linefeed & "0"
        end if
        tell application "Spotify" to \(command)
        delay 0.15
        tell application "Spotify"
            set trackName to ""
            set artistName to ""
            try
                set trackName to name of current track
                set artistName to artist of current track
            end try
            set elapsedSeconds to player position
            set durationSeconds to 0
            try
                set durationSeconds to (duration of current track) / 1000
            end try
            return (player state as text) & linefeed & trackName & linefeed & artistName & linefeed & elapsedSeconds & linefeed & durationSeconds
        end tell
        """
        runAppleScript(script) { output in
            applySpotifyPlaybackOutput(output)
            state.statusMessage = "Spotify: \(command)"
        }
    }

    private func syncSpotifyPlaybackState() {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                set trackName to ""
                set artistName to ""
                try
                    set trackName to name of current track
                    set artistName to artist of current track
                end try
                set elapsedSeconds to player position
                set durationSeconds to 0
                try
                    set durationSeconds to (duration of current track) / 1000
                end try
                return (player state as text) & linefeed & trackName & linefeed & artistName & linefeed & elapsedSeconds & linefeed & durationSeconds
            end tell
        else
            return "stopped" & linefeed & "" & linefeed & "Open Spotify or use the web browser to browse." & linefeed & "0" & linefeed & "0"
        end if
        """
        runAppleScript(script) { output in
            applySpotifyPlaybackOutput(output)
        }
    }

    private func applySpotifyPlaybackOutput(_ output: String?) {
        let lines = (output ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let playerState = lines.first ?? "stopped"
        externalNowPlayingTitle = lines.dropFirst().first(where: { !$0.isEmpty }) ?? "Spotify"
        externalNowPlayingSubtitle = lines.dropFirst(2).first(where: { !$0.isEmpty }) ?? "Native Spotify app"
        musicElapsedSeconds = parseMusicSeconds(lines.dropFirst(3).first)
        musicDurationSeconds = parseMusicSeconds(lines.dropFirst(4).first)
        spotifyPlaybackActive = playerState.lowercased() == "playing"
        syncDisplayedPlaybackActive()
    }

    private func parseMusicSeconds(_ value: String?) -> Int {
        guard let value,
              let seconds = Double(value.replacingOccurrences(of: ",", with: "."))
        else { return 0 }
        return max(0, Int(seconds.rounded()))
    }

    private func handlePlexMediaControl(command: String) {
        guard mediaSource == .plex else {
            state.statusMessage = "Switch to Plex to control Plex playback."
            return
        }

        if !musicWebViewMatchesSource(state.musicWebView, source: .plex) {
            loadMusicBrowserIfNeeded(for: .plex, force: true)
            state.statusMessage = "Loading Plex player..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard self.mediaSource == .plex else { return }
                self.handlePlexMediaControl(command: command)
            }
            return
        }

        externalNowPlayingTitle = "Plex"
        externalNowPlayingSubtitle = "Embedded Plex web player"
        evaluateWebPlayerControl(
            command: command,
            serviceName: "Plex",
            fallbackMessage: "Plex web did not expose that control yet.",
            fallbackAction: nil
        )
    }

    private func evaluateWebPlayerControl(command: String, serviceName: String, fallbackMessage: String, fallbackAction: (() -> Void)?) {
        guard let webView = state.musicWebView else {
            if serviceName == "Plex" {
                plexPlaybackActive = false
                syncDisplayedPlaybackActive()
            }
            fallbackAction?()
            if fallbackAction == nil {
                state.statusMessage = "Open \(serviceName) in the music sidecar first."
            }
            return
        }

        if serviceName == "Plex", !musicWebViewMatchesSource(webView, source: .plex) {
            state.statusMessage = "Open Plex in the music sidecar first."
            fallbackAction?()
            return
        }

        let script = webPlayerControlScript(for: command, serviceName: serviceName)
        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let dict = result as? [String: Any],
                      (dict["ok"] as? Bool) == true
                else {
                    self.state.statusMessage = fallbackMessage
                    fallbackAction?()
                    return
                }
                if let currentTime = dict["currentTime"] as? Double {
                    self.musicElapsedSeconds = Int(currentTime.rounded())
                }
                if let duration = dict["duration"] as? Double, duration.isFinite {
                    self.musicDurationSeconds = Int(duration.rounded())
                }
                if let paused = dict["paused"] as? Bool {
                    if serviceName == "Plex" {
                        self.plexPlaybackActive = !paused
                        self.syncDisplayedPlaybackActive()
                    }
                } else if serviceName == "Plex" {
                    self.syncWebPlayerProgress()
                }
                self.externalNowPlayingTitle = serviceName
                self.externalNowPlayingSubtitle = "Embedded \(serviceName) web player"
                self.state.statusMessage = "\(serviceName) player synced."
            }
        }
    }

    private func webPlayerControlScript(for command: String, serviceName: String) -> String {
        let labels: [String]
        switch command {
        case "playpause":
            labels = ["Play", "Pause", "Play/Pause", "Resume"]
        case "next track":
            labels = ["Next", "Skip Next", "next", "Skip Forward"]
        case "previous track":
            labels = ["Previous", "Skip Previous", "previous", "Skip Back"]
        case "shuffle":
            labels = ["Shuffle"]
        case "repeat":
            labels = ["Repeat"]
        default:
            labels = [command]
        }
        let labelsLiteral = labels.map { "'\($0.replacingOccurrences(of: "'", with: "\\'").lowercased())'" }.joined(separator: ",")
        let shouldToggleMedia = command == "playpause" ? "true" : "false"
        let serviceLiteral = serviceName.replacingOccurrences(of: "'", with: "\\'")

        return """
        (function() {
            var labels = [\(labelsLiteral)];
            var serviceName = '\(serviceLiteral)';
            var command = '\(command)';
            var media = document.querySelector('video') || document.querySelector('audio');
            if (\(shouldToggleMedia) && media) {
                if (media.paused) { media.play(); } else { media.pause(); }
                return {
                    ok: true,
                    paused: media.paused,
                    currentTime: media.currentTime || 0,
                    duration: isFinite(media.duration) ? media.duration : 0
                };
            }

            function collectButtons(root, output) {
                if (!root) return output;
                try {
                    output.push.apply(output, Array.from(root.querySelectorAll('button,[role="button"],a[role="button"]')));
                    Array.from(root.querySelectorAll('*')).forEach(function(node) {
                        if (node.shadowRoot) collectButtons(node.shadowRoot, output);
                    });
                } catch (error) {}
                return output;
            }

            function labelFor(item) {
                return ((item.getAttribute('aria-label') || '') + ' ' +
                    (item.getAttribute('data-testid') || '') + ' ' +
                    (item.title || '') + ' ' +
                    (item.textContent || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
            }

            function fireRealClick(item) {
                var rect = item.getBoundingClientRect();
                var x = rect.left + rect.width / 2;
                var y = rect.top + rect.height / 2;
                ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(type) {
                    try {
                        item.dispatchEvent(new MouseEvent(type, {
                            bubbles: true,
                            cancelable: true,
                            view: window,
                            clientX: x,
                            clientY: y
                        }));
                    } catch (error) {}
                });
                try { item.click(); } catch (error) {}
            }

            var buttons = collectButtons(document, []);
            var visible = buttons.map(function(item) {
                var rect = item.getBoundingClientRect();
                var text = labelFor(item);
                return { item: item, rect: rect, text: text };
            }).filter(function(entry) {
                return entry.rect.width > 0 && entry.rect.height > 0 &&
                    entry.rect.bottom >= 0 && entry.rect.top <= window.innerHeight &&
                    entry.rect.right >= 0 && entry.rect.left <= window.innerWidth;
            }).filter(function(entry) {
                return labels.some(function(label) { return entry.text.indexOf(label) >= 0; });
            }).map(function(entry) {
                var exact = labels.some(function(label) { return entry.text === label; }) ? 100 : 0;
                var aria = entry.item.getAttribute('aria-label') ? 40 : 0;
                var lowerHalf = entry.rect.top > window.innerHeight * 0.52 ? 80 : 0;
                var lowerRight = entry.rect.top > window.innerHeight * 0.52 && entry.rect.left > window.innerWidth * 0.25 ? 40 : 0;
                var compact = entry.rect.width <= 92 && entry.rect.height <= 92 ? 24 : 0;
                var spotifyControl = entry.text.indexOf('now-playing') >= 0 || entry.text.indexOf('control') >= 0 ? 20 : 0;
                entry.score = exact + aria + lowerHalf + lowerRight + compact + spotifyControl + entry.rect.top / Math.max(1, window.innerHeight);
                return entry;
            }).sort(function(a, b) {
                return b.score - a.score;
            });

            if (!visible.length) {
                return { ok: false, reason: 'no_button', service: serviceName, command: command };
            }
            var button = visible[0].item;
            fireRealClick(button);
            var nextMedia = document.querySelector('video') || document.querySelector('audio');
            return {
                ok: true,
                clicked: visible[0].text,
                service: serviceName,
                command: command,
                paused: nextMedia ? nextMedia.paused : null,
                currentTime: nextMedia ? (nextMedia.currentTime || 0) : 0,
                duration: nextMedia && isFinite(nextMedia.duration) ? nextMedia.duration : 0
            };
        })()
        """
    }

    private func runAppleScript(_ script: String, completion: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        process.terminationHandler = { process in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0 ? output : nil)
            }
        }
        do {
            try process.run()
        } catch {
            completion(nil)
        }
    }

    private func handleSpotifyMediaControl(command: String) {
        guard mediaSource == .spotify else {
            state.statusMessage = "Switch to Spotify to control the Spotify app."
            return
        }

        let nativeCommand: String
        switch command {
        case "shuffle":
            nativeCommand = "set shuffling to not shuffling"
        case "repeat":
            nativeCommand = "set repeating to not repeating"
        default:
            nativeCommand = command
        }
        sendSpotifyControl(command: nativeCommand)
    }

    private var albumArtCover: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.18, blue: 0.22), Color(red: 0.08, green: 0.08, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Circle()
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                .frame(width: 44, height: 44)
            Circle()
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                .frame(width: 28, height: 28)
            
            Image(systemName: mediaSource == .spotify ? "music.note" : (mediaSource == .plex ? "play.tv.fill" : "music.note"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.75, green: 0.48, blue: 1.0), Color(red: 0.34, green: 0.68, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)
    }

    private var musicStatusTitle: String {
        switch mediaSource {
        case .spotify:
            return externalNowPlayingTitle.isEmpty
                ? (state.notchPlaybackActive ? "Spotify Playing" : "Spotify Ready")
                : externalNowPlayingTitle
        case .plex:
            return externalNowPlayingTitle.isEmpty ? "Plex Browser" : externalNowPlayingTitle
        case .music:
            return state.notchPlaybackActive ? "Music Playing" : "Apple Music"
        }
    }

    private var musicStatusSubtitle: String {
        switch mediaSource {
        case .spotify:
            return externalNowPlayingSubtitle.isEmpty ? "Controls the native Spotify app" : externalNowPlayingSubtitle
        case .plex:
            return externalNowPlayingSubtitle.isEmpty ? "Browse Plex here; playback bridge next" : externalNowPlayingSubtitle
        case .music:
            return "Control system Apple Music library"
        }
    }

    private var musicProgressFraction: CGFloat {
        guard musicDurationSeconds > 0 else { return 0.42 } // default mock progress
        return min(1, max(0, CGFloat(musicElapsedSeconds) / CGFloat(musicDurationSeconds)))
    }

    private var filteredMusicTracks: [NotchMusicTrack] {
        let trimmed = musicSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return musicTracks }
        return musicTracks.filter { $0.searchText.lowercased().contains(trimmed) }
    }

    private var selectedMusicTrack: NotchMusicTrack? {
        guard let id = selectedMusicTrackID else { return nil }
        return musicTracks.first { $0.id == id }
    }

    private var webPlayerURL: String {
        switch mediaSource {
        case .spotify:
            return "https://open.spotify.com"
        case .plex:
            return "https://app.plex.tv"
        case .music:
            return "https://music.apple.com"
        }
    }

    private var visualizerGradient: LinearGradient {
        switch mediaSource {
        case .spotify:
            return LinearGradient(
                colors: [Color(red: 0.11, green: 0.72, blue: 0.33).opacity(0.25), Color(red: 0.11, green: 0.72, blue: 0.33).opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .plex:
            return LinearGradient(
                colors: [Color(red: 0.98, green: 0.68, blue: 0.08).opacity(0.25), Color(red: 0.98, green: 0.68, blue: 0.08).opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .music:
            return LinearGradient(
                colors: [Color(red: 0.75, green: 0.48, blue: 1.0).opacity(0.25), Color(red: 0.34, green: 0.68, blue: 1.0).opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var musicFolderIsReachable: Bool {
        guard !musicFolderPath.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: musicFolderPath, isDirectory: &isDir) && isDir.boolValue
    }

    private var musicFolderIsServerPath: Bool {
        musicFolderPath.contains("/Volumes/") || musicFolderPath.lowercased().contains("smb:") || musicFolderPath.lowercased().contains("media")
    }

    private var shouldShowMusicMountButton: Bool {
        musicFolderIsServerPath && !musicFolderIsReachable
    }

    private var musicStatusLabel: String {
        if !musicSearch.isEmpty {
            return "\(filteredMusicTracks.count) of \(musicTracks.count) tracks"
        }
        return "\(musicTracks.count) track\(musicTracks.count == 1 ? "" : "s") found"
    }

    private var musicEmptyText: String {
        if musicFolderPath.isEmpty {
            return "Pick a local or server music folder."
        }
        if shouldShowMusicMountButton {
            return "Server share is not mounted."
        }
        if scannedMusicFolderPath != musicFolderPath {
            return "Choose Folder loads it, or press Load."
        }
        if musicTracks.isEmpty {
            return "Press Load to scan this folder."
        }
        return "No matches in this folder."
    }



    private var cameraStatusTitle: String {
        if camera.authorizationDenied {
            return "Camera permission needed"
        }
        return camera.isRunning ? "Webcam shared" : "Webcam paused"
    }

    private var cameraStatusSubtitle: String {
        if camera.authorizationDenied {
            return "Enable Desk Agent camera access in System Settings."
        }
        return camera.isRunning ? "Showing in this chat view." : "Start when you want camera context."
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot shelf is empty.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
                Text("Screenshots, clips, files, and copied text collect here.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func batchCard(_ batch: CaptureShelfBatch, accent: Color) -> some View {
        ShelfBatchTile(state: state, batch: batch, accent: accent)
    }

    private func batchAccent(_ index: Int) -> Color {
        let colors = [
            Color(red: 0.36, green: 0.95, blue: 0.62),
            Color(red: 1.0, green: 0.36, blue: 0.42),
            Color(red: 0.34, green: 0.66, blue: 1.0),
            Color(red: 1.0, green: 0.72, blue: 0.28),
            Color(red: 0.75, green: 0.48, blue: 1.0)
        ]
        return colors[index % colors.count]
    }



    private func saveQuickNote() {
        state.saveQuickNoteToObsidian(quickNoteDraft)
        if !quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quickNoteDraft = ""
        }
    }

    private func copyQuickNote() {
        let trimmed = quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.statusMessage = "Nothing to copy."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        state.statusMessage = "Copied note to clipboard."
    }

    private func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a local music folder for the notch Music view."

        if panel.runModal() == .OK, let url = panel.url {
            musicFolderPath = url.path
            selectedMusicTrackID = nil
            musicSearch = ""
            musicTracks = []
            scannedMusicFolderPath = ""
            state.statusMessage = "Loading selected music folder..."
            refreshMusicTracks()
        } else {
            state.statusMessage = "Music folder selection cancelled."
        }
    }

    private func refreshMusicTracks() {
        guard !musicFolderPath.isEmpty else {
            musicTracks = []
            selectedMusicTrackID = nil
            musicSearch = ""
            isLoadingMusic = false
            scannedMusicFolderPath = ""
            return
        }

        guard musicFolderIsReachable else {
            musicTracks = []
            selectedMusicTrackID = nil
            isLoadingMusic = false
            scannedMusicFolderPath = ""
            state.statusMessage = musicFolderIsServerPath ? "Music server is not mounted." : "Music folder is not reachable."
            return
        }

        let folderPath = musicFolderPath
        let scanID = UUID()
        musicScanID = scanID
        isLoadingMusic = true
        state.statusMessage = "Scanning music folder..."

        Task.detached(priority: .utility) {
            let tracks = NotchMusicScanner.scan(folderPath: folderPath)
            await MainActor.run {
                guard musicScanID == scanID else { return }
                musicTracks = tracks
                scannedMusicFolderPath = folderPath
                isLoadingMusic = false
                if let selectedMusicTrackID,
                   !tracks.contains(where: { $0.id == selectedMusicTrackID }) {
                    self.selectedMusicTrackID = nil
                }
                if self.selectedMusicTrackID == nil {
                    self.selectedMusicTrackID = tracks.first?.id
                }
                state.statusMessage = tracks.isEmpty ? "No audio files found." : "Loaded \(tracks.count) tracks."
            }
        }
    }

    private func playSelectedMusicTrack() {
        guard musicFolderPath.isEmpty || musicFolderIsReachable else {
            state.statusMessage = musicFolderIsServerPath ? "Mount the music server first." : "Music folder is not reachable."
            return
        }
        guard let track = selectedMusicTrack else {
            state.statusMessage = musicFolderPath.isEmpty ? "Choose a music folder first." : "Pick or load a track first."
            return
        }
        playMusicTrack(track)
    }

    private func toggleMusicPlayback() {
        if mediaSource == .spotify || mediaSource == .plex {
            sendMediaControl(command: "playpause")
        } else {
            if state.notchPlaybackActive {
                pauseMusicPlayback()
            } else if musicPlayer != nil {
                resumeMusicPlayback()
            } else {
                playSelectedMusicTrack()
            }
        }
    }

    private func playNextMusicTrack() {
        playAdjacentMusicTrack(offset: 1)
    }

    private func playPreviousMusicTrack() {
        playAdjacentMusicTrack(offset: -1)
    }

    private func playRandomMusicTrack() {
        guard musicFolderPath.isEmpty || musicFolderIsReachable else {
            state.statusMessage = musicFolderIsServerPath ? "Mount the music server first." : "Music folder is not reachable."
            return
        }

        let tracks = filteredMusicTracks.isEmpty ? musicTracks : filteredMusicTracks
        guard !tracks.isEmpty else {
            state.statusMessage = "Load music first."
            return
        }

        if tracks.count == 1 {
            playMusicTrack(tracks[0])
            return
        }

        let currentID = selectedMusicTrackID ?? lastOpenedMusicTrackID
        let candidates = tracks.filter { $0.id != currentID }
        playMusicTrack(candidates.randomElement() ?? tracks.randomElement()!)
    }

    private func playAdjacentMusicTrack(offset: Int) {
        guard musicFolderPath.isEmpty || musicFolderIsReachable else {
            state.statusMessage = musicFolderIsServerPath ? "Mount the music server first." : "Music folder is not reachable."
            return
        }

        let tracks = filteredMusicTracks.isEmpty ? musicTracks : filteredMusicTracks
        guard !tracks.isEmpty else {
            state.statusMessage = "Load music first."
            return
        }

        let currentID = selectedMusicTrackID ?? lastOpenedMusicTrackID
        let currentIndex = currentID.flatMap { id in tracks.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = (currentIndex + offset + tracks.count) % tracks.count
        playMusicTrack(tracks[nextIndex])
    }

    private func playMusicTrack(_ track: NotchMusicTrack) {
        guard FileManager.default.fileExists(atPath: track.url.path) else {
            stopMusicPlayback(updateStatus: false)
            state.statusMessage = "Track is not reachable. Mount the folder and reload."
            return
        }

        stopMusicPlayback(updateStatus: false)
        selectedMusicTrackID = track.id
        lastOpenedMusicTrackID = track.id

        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.prepareToPlay()
            player.play()
            musicPlayer = player
            musicElapsedSeconds = Int(player.currentTime)
            musicDurationSeconds = Int(player.duration.rounded())
            state.notchPlaybackActive = true
            state.statusMessage = "Playing \(track.title)."
        } catch {
            state.notchPlaybackActive = false
            state.statusMessage = "Could not play \(track.title): \(error.localizedDescription)"
        }
    }

    private func stopMusicPlayback(updateStatus: Bool = true) {
        musicPlayer?.stop()
        musicPlayer = nil
        musicElapsedSeconds = 0
        musicDurationSeconds = 0
        state.notchPlaybackActive = false
        if updateStatus {
            state.statusMessage = "Music stopped."
        }
    }

    private func pauseMusicPlayback() {
        guard let musicPlayer else {
            state.notchPlaybackActive = false
            return
        }

        musicPlayer.pause()
        musicElapsedSeconds = Int(musicPlayer.currentTime.rounded())
        musicDurationSeconds = Int(musicPlayer.duration.rounded())
        state.notchPlaybackActive = false
        state.statusMessage = "Music paused."
    }

    private func resumeMusicPlayback() {
        guard let musicPlayer else {
            playSelectedMusicTrack()
            return
        }

        musicPlayer.play()
        state.notchPlaybackActive = true
        state.statusMessage = "Music resumed."
    }

    private func updateMusicProgress() {
        guard let musicPlayer else { return }
        musicElapsedSeconds = Int(musicPlayer.currentTime.rounded())
        musicDurationSeconds = Int(musicPlayer.duration.rounded())
        if state.notchPlaybackActive, !musicPlayer.isPlaying, musicPlayer.currentTime >= musicPlayer.duration - 0.25 {
            playNextMusicTrack()
        }
    }

    private func syncWebPlayerProgress() {
        guard let webView = state.musicWebView, musicWebViewMatchesSource(webView, source: .plex) else {
            if mediaSource == .plex {
                plexPlaybackActive = false
                syncDisplayedPlaybackActive()
            }
            return
        }
        let js = """
        (function() {
            var media = document.querySelector('video') || document.querySelector('audio');
            if (media) {
                return {
                    currentTime: media.currentTime,
                    duration: media.duration,
                    paused: media.paused
                };
            }
            return null;
        })()
        """
        webView.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async {
                guard error == nil, let dict = result as? [String: Any] else {
                    if self.mediaSource == .plex {
                        self.plexPlaybackActive = false
                        self.syncDisplayedPlaybackActive()
                    }
                    return
                }
                if let currentTime = dict["currentTime"] as? Double,
                   let duration = dict["duration"] as? Double {
                    self.musicElapsedSeconds = Int(currentTime)
                    self.musicDurationSeconds = Int(duration)
                }
                if let paused = dict["paused"] as? Bool {
                    self.plexPlaybackActive = !paused
                    self.syncDisplayedPlaybackActive()
                    self.externalNowPlayingTitle = "Plex"
                    self.externalNowPlayingSubtitle = self.pausedDescription(dict["paused"])
                } else if self.mediaSource == .plex {
                    self.plexPlaybackActive = false
                    self.syncDisplayedPlaybackActive()
                }
            }
        }
    }

    private func pausedDescription(_ value: Any?) -> String {
        if let paused = value as? Bool {
            return paused ? "Embedded Plex player paused" : "Embedded Plex player playing"
        }
        return "Embedded Plex web player"
    }

    private func formatMusicTime(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):\(String(format: "%02d", clamped % 60))"
    }

    private func revealMusicFolder() {
        guard !musicFolderPath.isEmpty else {
            state.statusMessage = "Choose a music folder first."
            return
        }
        guard musicFolderIsReachable else {
            state.statusMessage = musicFolderIsServerPath ? "Mount the music server first." : "Music folder is not reachable."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: musicFolderPath, isDirectory: true)])
    }

    private func mountMusicServer() {
        guard let url = URL(string: musicServerURL), !musicServerURL.isEmpty else {
            state.statusMessage = "No music server URL saved."
            return
        }

        NSWorkspace.shared.open(url)
        state.statusMessage = "Opening music server mount. Press Load after it appears."
    }

    private func loadSwitchboardServices() {
        let services = NotchSwitchboardRegistry.load()
        switchboardServices = services
        if !services.isEmpty, switchboardReachability.isEmpty {
            refreshSwitchboardHealth()
        }
    }

    private func refreshSwitchboardHealth() {
        if switchboardServices.isEmpty {
            loadSwitchboardServices()
        }

        let services = switchboardServices
        guard !services.isEmpty else {
            state.statusMessage = "No switchboard services found."
            return
        }

        isCheckingSwitchboard = true
        state.statusMessage = "Checking switchboard services..."

        Task {
            let results = await NotchSwitchboardHealthChecker.check(services)
            await MainActor.run {
                switchboardReachability = results
                switchboardLastChecked = Date()
                isCheckingSwitchboard = false
                let up = results.values.filter { $0 }.count
                state.statusMessage = "Switchboard checked: \(up)/\(results.count) reachable."
            }
        }
    }

    private func openSwitchboardService(_ service: NotchSwitchboardService) {
        if let url = service.url {
            NSWorkspace.shared.open(url)
            state.statusMessage = "Opening \(service.name)."
            return
        }

        if let folderPath = service.folderPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folderPath)])
            state.statusMessage = "Opening \(service.name)."
            return
        }

        state.statusMessage = "\(service.name) has no target."
    }

    private func openFullSwitchboard() {
        if let path = DeskAgentLocalPaths.switchboardAppPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            state.statusMessage = "Opening Service Switchboard."
            return
        }

        revealSwitchboardRegistry()
        state.statusMessage = "Service Switchboard app not found. Opened registry instead."
    }

    private func revealSwitchboardRegistry() {
        let url = URL(fileURLWithPath: NotchSwitchboardRegistry.defaultPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        state.statusMessage = "Opening switchboard registry."
    }

    private func submitChatPeek() {
        let trimmed = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && chatPendingAttachments.isEmpty {
            return
        }
        sendHermesChat(trimmed.isEmpty ? "Review the attached item(s)." : trimmed)
        chatDraft = ""
    }

    private func toggleNotchListening() {
        if state.notchListeningEnabled {
            stopLiveSession()
            return
        }

        refreshLiveReadiness { readiness in
            if readiness.isReady {
                startLiveSession()
            } else {
                state.statusMessage = readiness.nextStep
            }
        }
    }

    private func startTalkFromShortcut() {
        state.showNotchShelf()
        state.notchShelfExpanded = true
        activeModule = .chat

        if state.notchListeningEnabled || liveVoice.isActive || isChangingLiveSession {
            state.statusMessage = "Talk to Hermes is already active."
            return
        }

        refreshLiveReadiness { readiness in
            if readiness.isReady {
                startLiveSession()
            } else {
                state.statusMessage = readiness.nextStep
            }
        }
    }

    private func triggerQAStartLive(attempt: Int) {
        guard qaAutoStartLiveEnabled else { return }
        guard !state.notchListeningEnabled, !liveVoice.isActive else { return }
        guard attempt < 12 else {
            MarkShotLog.write("qa auto start live gave up waiting for page ready")
            return
        }
        if liveVoice.pageReady {
            MarkShotLog.write("qa auto start live now invoking startTalkFromShortcut attempt=\(attempt)")
            startTalkFromShortcut()
            return
        }
        MarkShotLog.write("qa auto start live waiting for page ready attempt=\(attempt)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            self.triggerQAStartLive(attempt: attempt + 1)
        }
    }

    private func handleAutoStopRequested() {
        guard !qaAutoStopTriggered else { return }
        qaAutoStopTriggered = true
        guard state.notchListeningEnabled || liveVoice.isActive else {
            state.statusMessage = "No active live session to stop."
            return
        }
        stopLiveSession()
    }

    private func mountLiveVoiceBridgeIfNeeded() {
        guard !liveVoiceBridgeMounted else { return }
        liveVoiceBridgeMounted = true
        MarkShotLog.write("live voice bridge webview mounted")
    }

    private func resetVisualizerHeights() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            visualizerHeights = Array(repeating: 4.0, count: 26)
        }
    }

    private func startLiveSession() {
        mountLiveVoiceBridgeIfNeeded()
        guard !isChangingLiveSession else { return }
        guard liveVoice.pageReady else {
            liveVoice.reloadBridge()
            state.statusMessage = "Live voice shell is loading. Tap Listen again in a moment."
            refreshLiveReadiness()
            return
        }
        resetLiveTranscriptState()
        wakePhrase.stop()
        isChangingLiveSession = true
        state.statusMessage = "Starting live voice session..."
        let conversationId = ensureDeskAgentConversationId()
        Task {
            await liveVoice.start(conversationId: conversationId)
            await MainActor.run {
                isChangingLiveSession = false
                if !liveVoice.warning.isEmpty {
                    state.statusMessage = "Live voice start failed: \(liveVoice.warning)"
                } else {
                    state.statusMessage = "Starting live voice..."
                }
            }
        }
    }

    private func ensureDeskAgentConversationId() -> String {
        let trimmed = deskAgentConversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let created = "notch-\(UUID().uuidString.lowercased())"
        deskAgentConversationId = created
        return created
    }

    private func stopLiveSession() {
        if !liveVoice.isActive, let session = activePhoneSession {
            state.statusMessage = "Stopping phone live session..."
            Task {
                try? await bridgeClient.endLiveSession(id: session.id, helperAuthToken: "")
                await MainActor.run {
                    state.statusMessage = "Phone live session stopped."
                    refreshLiveReadiness()
                }
            }
            return
        }

        guard !isChangingLiveSession else { return }
        isChangingLiveSession = true
        state.statusMessage = "Stopping live voice session..."
        Task {
            await liveVoice.stop()
            await MainActor.run {
                if state.notchListeningEnabled {
                    state.toggleNotchListening()
                }
                resetLiveTranscriptState()
                isChangingLiveSession = false
                state.statusMessage = "Live voice session stopped."
                refreshLiveReadiness()
                restartWakePhraseListeningIfNeeded()
            }
        }
    }

    private func resetLiveTranscriptState() {
        lastChatLiveUserTranscript = ""
        lastChatLiveAssistantTranscript = ""
        liveVoice.resetTranscriptState()
    }

    private func configureWakePhrase() {
        wakePhrase.onWake = {
            Task { @MainActor in
                handleWakePhraseDetected()
            }
        }
    }

    private func toggleWakeListening() {
        wakeListeningEnabled.toggle()
    }

    private func startWakePhraseListening() {
        guard wakeListeningEnabled else { return }
        guard !liveVoice.isActive, !state.notchListeningEnabled, !isChangingLiveSession else { return }
        state.statusMessage = "Wake listening is on. Say hey agent to start live voice."
        Task {
            await wakePhrase.start()
            await MainActor.run {
                if !wakePhrase.warning.isEmpty {
                    state.statusMessage = wakePhrase.warning
                }
            }
        }
    }

    private func restartWakePhraseListeningIfNeeded() {
        guard wakeListeningEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            startWakePhraseListening()
        }
    }

    private func handleWakePhraseDetected() {
        state.statusMessage = "Wake phrase heard. Starting live voice..."
        if !state.notchListeningEnabled && !liveVoice.isActive {
            toggleNotchListening()
        }
    }

    private func syncNotchListening(with liveState: String) {
        switch liveState {
        case "listening", "thinking", "replying", "learn", "connecting":
            if !state.notchListeningEnabled {
                state.toggleNotchListening()
            }
        case "idle", "offline", "blocked":
            if state.notchListeningEnabled {
                state.toggleNotchListening()
            }
            if liveState == "blocked", !liveVoice.warning.isEmpty {
                state.statusMessage = liveVoice.warning
            }
            restartWakePhraseListeningIfNeeded()
        default:
            break
        }
    }

    private func shouldStopLiveSession(from transcript: String) -> Bool {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let stopPhrases = [
            "ok we good",
            "okay we good",
            "ok we re good",
            "okay we re good",
            "ok we're good",
            "okay we're good",
            "we good",
            "we re good",
            "we're good",
            "were good",
            "we are good"
        ]

        return stopPhrases.contains { phrase in
            normalized == phrase ||
            normalized.hasPrefix("\(phrase) ") ||
            normalized.hasSuffix(" \(phrase)") ||
            normalized.contains(" \(phrase) ")
        }
    }

    private func refreshLiveReadiness(onComplete: ((DeskAgentLiveReadiness) -> Void)? = nil) {
        guard !isCheckingLiveReadiness else { return }
        lastBridgeRefreshAt = Date()
        isCheckingLiveReadiness = true
        liveReadinessError = ""
        Task {
            do {
                let status = try await bridgeClient.fetchNotchStatus()
                await MainActor.run {
                    notchBridgeStatus = status
                    syncBridgeConversationTurns(status)
                    liveReadiness = status.liveReadiness
                    liveReadinessError = ""
                    isCheckingLiveReadiness = false
                    onComplete?(status.liveReadiness)
                }
            } catch {
                await MainActor.run {
                    notchBridgeStatus = nil
                    liveReadiness = nil
                    liveReadinessError = error.localizedDescription
                    isCheckingLiveReadiness = false
                    state.statusMessage = "Hermes text ready. Live/phone helper offline: \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshBridgeStatusIfNeeded(now: Date) {
        let interval: TimeInterval = expanded ? 3 : 8
        guard now.timeIntervalSince(lastBridgeRefreshAt) >= interval else { return }
        guard !isCheckingLiveReadiness else { return }
        refreshLiveReadiness()
    }

    private func syncBridgeConversationTurns(_ status: DeskAgentNotchStatus) {
        let turns = status.recentConversationTurns
        guard !turns.isEmpty else { return }

        let unseenTurns: [DeskAgentConversationTurn]
        if lastBridgeConversationTurnID.isEmpty {
            unseenTurns = turns
                .filter { !seenBridgeConversationTurnIDs.contains($0.id) }
                .prefix(1)
                .map { $0 }
        } else if let lastIndex = turns.firstIndex(where: { $0.id == lastBridgeConversationTurnID }) {
            unseenTurns = Array(turns[..<lastIndex]).reversed()
        } else {
            unseenTurns = turns
                .filter { !seenBridgeConversationTurnIDs.contains($0.id) }
                .reversed()
        }

        for turn in unseenTurns {
            seenBridgeConversationTurnIDs.insert(turn.id)
            appendBridgeConversationTurn(turn)
            lastBridgeConversationTurnID = turn.id
        }
    }

    private func appendBridgeConversationTurn(_ turn: DeskAgentConversationTurn) {
        let userText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userText.isEmpty {
            chatMessages.append(NotchChatMessage(role: .user, text: userText, source: turn.source))
        }

        let responseText = turn.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseText.isEmpty {
            chatMessages.append(NotchChatMessage(role: .assistant, text: responseText, source: turn.source))
        }

        let friendlySource = turn.source == "iphone" ? "phone" : (turn.source == "shortcut" ? "shortcut" : "phone")
        state.statusMessage = "Turn from \(friendlySource) added to chat."
    }

    private func appendLiveVoiceTranscript(role: NotchChatRole, transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let voicePrefix = text.hasPrefix("Voice: ") ? text : "Voice: \(text)"

        switch role {
        case .user:
            MarkShotLog.write("chat append live user len=\(text.count)")
            guard voicePrefix != lastChatLiveUserTranscript else { return }
            lastChatLiveUserTranscript = voicePrefix
            chatMessages.append(NotchChatMessage(role: .user, text: voicePrefix, source: "live session"))
        case .assistant:
            MarkShotLog.write("chat append live assistant len=\(text.count)")
            guard text != lastChatLiveAssistantTranscript else { return }
            lastChatLiveAssistantTranscript = text
            chatMessages.append(NotchChatMessage(role: .assistant, text: text, source: "live session"))
        case .system:
            chatMessages.append(NotchChatMessage(role: .system, text: text))
        }
    }

    private func importLatestAirSend() {
        guard let item = latestAirSend else {
            state.statusMessage = "No AirSend item to import."
            return
        }

        if item.kind == "image", let filePath = item.filePath {
            guard let image = NSImage(contentsOfFile: filePath) else {
                state.statusMessage = "AirSend image is not reachable."
                return
            }
            state.prependShelfBatch(CaptureShelfBatch(images: [image], createdAt: Date()))
            state.statusMessage = "Imported AirSend image to the shelf."
            activeModule = .shelf
            state.notchShelfExpanded = true
            consumeImportedAirSend(item)
            return
        }

        let text = (item.text ?? item.label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.statusMessage = "AirSend item has no text to import."
            return
        }
        chatDraft = text
        activeModule = .chat
        state.statusMessage = "Loaded AirSend text into Hermes chat."
        consumeImportedAirSend(item)
    }

    private func consumeImportedAirSend(_ item: DeskAgentAirSend) {
        Task {
            do {
                try await bridgeClient.consumeAirSend(id: item.id)
                let status = try await bridgeClient.fetchNotchStatus()
                await MainActor.run {
                    notchBridgeStatus = status
                    syncBridgeConversationTurns(status)
                }
            } catch {
                await MainActor.run {
                    state.statusMessage = "Imported AirSend, but could not clear it from the helper."
                }
            }
        }
    }

    private func restoreChatHistory() {
        guard !chatHistoryJSON.isEmpty,
              let data = chatHistoryJSON.data(using: .utf8),
              let restored = try? JSONDecoder().decode([NotchChatMessage].self, from: data),
              !restored.isEmpty
        else {
            return
        }
        chatMessages = Array(restored.suffix(20))
    }

    private func persistChatHistory() {
        if chatMessages.count > maxLocalChatMessages {
            chatMessages = Array(chatMessages.suffix(maxLocalChatMessages))
        }
        let trimmed = Array(chatMessages.suffix(maxPersistedChatMessages))
        guard let data = try? JSONEncoder().encode(trimmed),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        chatHistoryJSON = json
    }

    private func copyChatTranscript() {
        let transcript = chatTranscriptMarkdown()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.statusMessage = "No chat transcript to copy."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        state.statusMessage = "Copied visible Hermes transcript."
    }

    private func archiveChatTranscriptToObsidian() {
        let transcript = chatTranscriptMarkdown()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.statusMessage = "No chat transcript to archive."
            return
        }
        do {
            try AppState.appendQuickNoteToObsidian(transcript)
            state.statusMessage = "Archived visible Hermes chat to Obsidian."
        } catch {
            state.statusMessage = "Chat archive failed: \(error.localizedDescription)"
        }
    }

    private func chatTranscriptMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let titleDate = formatter.string(from: Date())
        let session = hermesSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionLine = session.isEmpty ? "Hermes session: new / not captured yet" : "Hermes session: `\(session)`"
        let visibleCount = min(chatMessages.count, maxPersistedChatMessages)

        var lines: [String] = [
            "## Hermes Chat Snapshot - \(titleDate)",
            "",
            "- \(sessionLine)",
            "- Visible Notch transcript: last \(visibleCount) message\(visibleCount == 1 ? "" : "s")",
            "- Note: Hermes keeps deeper context through its own session; this is a lightweight UI archive.",
            ""
        ]

        for message in chatMessages.suffix(maxPersistedChatMessages) {
            let role: String
            switch message.role {
            case .user: role = "Will"
            case .assistant: role = "Hermes"
            case .system: role = "Desk Agent"
            }
            let source = (message.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceSuffix = source.isEmpty ? "" : " via \(source)"
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("### \(role)\(sourceSuffix)")
            lines.append("")
            lines.append(text.isEmpty ? "_No text._" : text)
            if !message.attachments.isEmpty {
                lines.append("")
                lines.append("Attachments:")
                for attachment in message.attachments {
                    lines.append("- \(attachment.title): `\(attachment.url.path.isEmpty ? attachment.url.absoluteString : attachment.url.path)`")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func resetHermesChat() {
        hermesSessionId = ""
        chatPendingAttachments = []
        chatMessages = [
            NotchChatMessage(role: .system, text: "New Hermes chat ready.")
        ]
        persistChatHistory()
        state.statusMessage = "Started a new Hermes chat."
    }

    private func openHermesPopout(at screenPoint: CGPoint? = nil) {
        let controller = chatPopoutController ?? HermesChatPopoutController()
        chatPopoutController = controller
        if let screenPoint {
            controller.setSpawnPosition(screenPoint)
        }
        controller.show(
            rootView: HermesChatPopoutView(
                messages: Binding(
                    get: { chatMessages },
                    set: { chatMessages = $0 }
                ),
                draft: Binding(
                    get: { chatDraft },
                    set: { chatDraft = $0 }
                ),
                pendingAttachments: Binding(
                    get: { chatPendingAttachments },
                    set: { chatPendingAttachments = $0 }
                ),
                isSending: isSendingToHermes,
                thinkingLabel: hermesThinkingLabel,
                onSend: submitChatPeek,
                onAttachLatest: openChatAttachmentPicker,
                onAttachCapture: attachLatestShelfImageToChat,
                onAttachClipboard: attachClipboardToChat,
                onAddMacContext: addCurrentMacContextToChat,
                onDropProviders: handleChatDrop,
                onNewChat: resetHermesChat,
                onOpenSkills: openHermesSkillsReference,
                onDockLeft: { controller.dock(to: .left) },
                onDockRight: { controller.dock(to: .right) }
            )
        )
    }

    private func openHermesSidecar() {
        let controller = hermesSidecarController ?? HermesSidecarWindowController()
        hermesSidecarController = controller

        if controller.isVisible {
            controller.toggle()
            return
        }

        controller.show(
            rootView: HermesSidecarView(
                state: state,
                controller: controller,
                messages: Binding(
                    get: { chatMessages },
                    set: { chatMessages = $0 }
                ),
                draft: Binding(
                    get: { chatDraft },
                    set: { chatDraft = $0 }
                ),
                pendingAttachments: Binding(
                    get: { chatPendingAttachments },
                    set: { chatPendingAttachments = $0 }
                ),
                mediaSource: Binding(
                    get: { mediaSource },
                    set: { mediaSource = $0 }
                ),
                liveReadiness: Binding(
                    get: { liveReadiness },
                    set: { liveReadiness = $0 }
                ),
                notchBridgeStatus: Binding(
                    get: { notchBridgeStatus },
                    set: { notchBridgeStatus = $0 }
                ),
                liveReadinessError: Binding(
                    get: { liveReadinessError },
                    set: { liveReadinessError = $0 }
                ),
                isCheckingLiveReadiness: Binding(
                    get: { isCheckingLiveReadiness },
                    set: { isCheckingLiveReadiness = $0 }
                ),
                hermesSessionId: hermesSessionId,
                localChatCount: chatMessages.count,
                persistedChatLimit: maxPersistedChatMessages,
                isSending: isSendingToHermes,
                thinkingLabel: hermesThinkingLabel,
                onSend: submitChatPeek,
                onAttachLatest: openChatAttachmentPicker,
                onAttachCapture: attachLatestShelfImageToChat,
                onAttachClipboard: attachClipboardToChat,
                onAddMacContext: addCurrentMacContextToChat,
                onMusicControl: sendMediaControl,
                onSelectMediaSource: handleMediaSourceSelected,
                onDropProviders: handleChatDrop,
                onNewChat: resetHermesChat,
                onArchiveChat: archiveChatTranscriptToObsidian,
                onCopyChat: copyChatTranscript,
                onRefreshStatus: { refreshLiveReadiness() },
                onToggle: { controller.toggle() }
            )
        )
    }

    private func handleMediaSourceSelected(_ source: MediaSource) {
        mediaSource = source
        loadMusicBrowserIfNeeded(for: source)
        syncDisplayedPlaybackActive()
        refreshActiveMediaSourceStateForSource(source)
        if source == .plex {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard self.mediaSource == .plex else { return }
                self.syncWebPlayerProgress()
            }
        }
    }

    private func attachLatestShelfImageToChat() {
        guard let image = state.shelfBatches.first?.images.first,
              let url = writeChatAttachmentImage(image)
        else {
            state.statusMessage = "No shelf image to attach."
            return
        }
        addPendingChatAttachment(url)
        state.statusMessage = "Attached latest shelf image."
    }

    private func openChatAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = "Attach files, folders, images, or videos for Hermes context."

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        urls.forEach(addPendingChatAttachment)
        activeModule = .chat
        state.statusMessage = "Attached \(urls.count) item\(urls.count == 1 ? "" : "s") to Hermes chat."
    }

    private func attachClipboardToChat() {
        let pasteboard = NSPasteboard.general

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) {
            let urls = objects.compactMap { object -> URL? in
                if let url = object as? URL { return url }
                return (object as? NSURL)?.absoluteURL
            }
            if !urls.isEmpty {
                urls.forEach(addPendingChatAttachment)
                activeModule = .chat
                state.statusMessage = "Attached \(urls.count) clipboard item\(urls.count == 1 ? "" : "s") to Hermes chat."
                return
            }
        }

        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: imageData),
           let url = writeChatAttachmentImage(image) {
            addPendingChatAttachment(url)
            activeModule = .chat
            state.statusMessage = "Attached clipboard image to Hermes chat."
            return
        }

        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            appendTextToChatDraft("""
            Clipboard:
            \(text)
            """)
            activeModule = .chat
            state.statusMessage = "Loaded clipboard text into Hermes chat."
            return
        }

        state.statusMessage = "Clipboard has nothing Hermes can attach."
    }

    private func addCurrentMacContextToChat() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            state.statusMessage = "No frontmost app context available."
            return
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
        var lines = [
            "Current Mac context:",
            "- App: \(appName)"
        ]
        if let bundleIdentifier = app.bundleIdentifier {
            lines.append("- Bundle: \(bundleIdentifier)")
        }
        if let executablePath = app.executableURL?.path {
            lines.append("- Executable: \(executablePath)")
        }
        if let windowTitle = frontmostWindowTitle(for: app.processIdentifier) {
            lines.append("- Window: \(windowTitle)")
        }

        appendTextToChatDraft(lines.joined(separator: "\n"))
        activeModule = .chat
        state.statusMessage = "Loaded current Mac context into Hermes chat."
    }

    private func frontmostWindowTitle(for processIdentifier: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            let ownerPID = window[kCGWindowOwnerPID as String] as? Int
            let layer = window[kCGWindowLayer as String] as? Int
            guard ownerPID == Int(processIdentifier), layer == 0 else { continue }
            if let name = window[kCGWindowName as String] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return nil
    }

    private func appendTextToChatDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatDraft = trimmed
        } else {
            chatDraft += "\n\n" + trimmed
        }
    }

    private func writeChatAttachmentImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-hermes-attachment-\(UUID().uuidString).png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func sendHermesChat(_ prompt: String) {
        guard !prompt.isEmpty, !isSendingToHermes else {
            return
        }

        let userAttachments = chatPendingAttachments
        let attachedImageURL = userAttachments.first(where: { $0.isLocalImage })?.url
        let promptWithAttachmentContext = prompt + attachmentContextPrompt(for: userAttachments)

        chatMessages.append(NotchChatMessage(role: .user, text: prompt, attachments: userAttachments))
        chatPendingAttachments = []
        isSendingToHermes = true
        hermesStartedAt = Date()
        hermesElapsedSeconds = 0
        state.statusMessage = userAttachments.isEmpty ? "Sending to Hermes..." : "Sending \(userAttachments.count) attachment\(userAttachments.count == 1 ? "" : "s") to Hermes..."

        Task {
            do {
                let result = try await hermesClient.sendMessage(
                    promptWithAttachmentContext,
                    resumeSessionId: hermesSessionId.isEmpty ? nil : hermesSessionId,
                    imagePath: attachedImageURL?.path
                )
                await MainActor.run {
                    hermesSessionId = result.sessionId
                    chatMessages.append(
                        NotchChatMessage(
                            role: .assistant,
                            text: result.response,
                            attachments: chatAttachments(in: result.response)
                        )
                    )
                    isSendingToHermes = false
                    hermesStartedAt = nil
                    hermesElapsedSeconds = 0
                    state.statusMessage = "Hermes replied."
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(NotchChatMessage(role: .system, text: error.localizedDescription))
                    isSendingToHermes = false
                    hermesStartedAt = nil
                    hermesElapsedSeconds = 0
                    state.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func addPendingChatAttachment(_ url: URL) {
        let attachment = NotchChatAttachment(url: url, kind: Self.chatAttachmentKind(for: url))
        guard !chatPendingAttachments.contains(where: { $0.url == attachment.url }) else { return }
        chatPendingAttachments.append(attachment)
    }

    private func removePendingAttachment(_ attachment: NotchChatAttachment) {
        chatPendingAttachments.removeAll { $0.id == attachment.id || $0.url == attachment.url }
    }

    private func attachmentContextPrompt(for attachments: [NotchChatAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let lines = attachments.map { attachment in
            "- \(attachment.title) [\(attachment.kind.rawValue)]: \(attachment.url.path)"
        }.joined(separator: "\n")
        return """


        Attached local context:
        \(lines)
        """
    }

    private func handleChatDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false

        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                    guard let url = item else { return }
                    DispatchQueue.main.async {
                        addPendingChatAttachment(url)
                        activeModule = .chat
                        state.statusMessage = "Attached \(url.lastPathComponent)."
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let itemURL = item as? URL {
                        url = itemURL
                    } else if let data = item as? Data,
                              let string = String(data: data, encoding: .utf8) {
                        url = URL(string: string)
                    } else if let string = item as? String {
                        url = URL(string: string)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        addPendingChatAttachment(url)
                        activeModule = .chat
                        state.statusMessage = "Attached \(url.lastPathComponent)."
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data,
                          let image = NSImage(data: data),
                          let url = writeChatAttachmentImage(image) else { return }
                    DispatchQueue.main.async {
                        addPendingChatAttachment(url)
                        activeModule = .chat
                        state.statusMessage = "Attached dropped image."
                    }
                }
            }
        }

        return accepted
    }

    private func chatAttachments(in text: String) -> [NotchChatAttachment] {
        let patterns: [String] = [
            #"file://[^\s\])>"']+"#,
            #"/(?:Users|tmp|var|private/var)/[^\n\r\t\])>"']+"#,
            #"https?://[^\s\])>"']+"#
        ]
        var seen = Set<String>()
        var attachments: [NotchChatAttachment] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let raw = sanitizedAttachmentCandidate(String(text[matchRange]))
                let url: URL?
                if raw.hasPrefix("file://") || raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                    url = URL(string: raw)
                } else {
                    url = URL(fileURLWithPath: raw)
                }
                guard let url else { continue }
                let key = url.absoluteString
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                attachments.append(NotchChatAttachment(url: url, kind: Self.chatAttachmentKind(for: url)))
            }
        }

        return attachments
    }

    private func sanitizedAttachmentCandidate(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)>]}'\" \n\r\t"))
    }

    fileprivate static let chatDropTypes: [UTType] = [.fileURL, .url, .image, .movie, .data]

    private static func chatAttachmentKind(for url: URL) -> NotchChatAttachmentKind {
        if url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return .localFolder
            }

            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
                return .localImage
            }
            if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) {
                return .localVideo
            }
            return .localFile
        }

        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            return .remoteImage
        }
        return .remoteFile
    }

    private func notchSurface(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) -> some View {
        ReferenceNotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.98),
                        Color.black.opacity(0.93)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                ReferenceNotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                    .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.white.opacity(0.045))
                    .frame(width: 170, height: 1)
            }
    }

    private func compactNotchSurface(flareWidth: CGFloat, flareHeight: CGFloat, bottomCornerRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let bodyWidth = max(0, width - flareWidth * 2)

            ZStack(alignment: .topLeading) {
                ReferenceNotchShape(topCornerRadius: 0, bottomCornerRadius: bottomCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.93)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: bodyWidth, height: height)
                    .overlay(
                        ReferenceNotchShape(topCornerRadius: 0, bottomCornerRadius: bottomCornerRadius)
                            .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
                    )
                    .offset(x: flareWidth)

                ExternalCornerFlare(side: .left)
                    .fill(Color.black.opacity(0.98))
                    .frame(width: flareWidth, height: flareHeight)
                    .offset(x: 0, y: 0)

                ExternalCornerFlare(side: .right)
                    .fill(Color.black.opacity(0.98))
                    .frame(width: flareWidth, height: flareHeight)
                    .offset(x: width - flareWidth, y: 0)
            }
        }
    }

    private func confirmQuitDeskAgent() {
        let alert = NSAlert()
        alert.messageText = "Quit Desk Agent?"
        alert.informativeText = "This will stop the notch app, screenshot hotkeys, chat, music, and switchboard until you reopen it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

}



private struct ReferenceNotchShape: InsettableShape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let topR = min(topCornerRadius, insetRect.width / 2, insetRect.height / 2)
        let bottomR = min(bottomCornerRadius, insetRect.width / 2, insetRect.height / 2)

        var path = Path()

        path.move(to: CGPoint(x: insetRect.minX, y: insetRect.minY))
        path.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.minY))

        if topR > 0 {
            path.addQuadCurve(
                to: CGPoint(x: insetRect.maxX - topR, y: insetRect.minY + topR),
                control: CGPoint(x: insetRect.maxX - topR, y: insetRect.minY)
            )
        }

        path.addLine(to: CGPoint(x: insetRect.maxX - topR, y: insetRect.maxY - bottomR))
        path.addQuadCurve(
            to: CGPoint(x: insetRect.maxX - topR - bottomR, y: insetRect.maxY),
            control: CGPoint(x: insetRect.maxX - topR, y: insetRect.maxY)
        )
        path.addLine(to: CGPoint(x: insetRect.minX + topR + bottomR, y: insetRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: insetRect.minX + topR, y: insetRect.maxY - bottomR),
            control: CGPoint(x: insetRect.minX + topR, y: insetRect.maxY)
        )

        if topR > 0 {
            path.addLine(to: CGPoint(x: insetRect.minX + topR, y: insetRect.minY + topR))
            path.addQuadCurve(
                to: CGPoint(x: insetRect.minX, y: insetRect.minY),
                control: CGPoint(x: insetRect.minX + topR, y: insetRect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: insetRect.minX, y: insetRect.minY))
        }

        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private enum ExternalCornerFlareSide {
    case left
    case right
}

private struct ExternalCornerFlare: Shape {
    let side: ExternalCornerFlareSide

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch side {
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        return path
    }
}

private struct NotchMusicTrack: Identifiable, Sendable {
    let url: URL

    var id: String {
        url.path
    }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    var folderName: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    var searchText: String {
        [
            title,
            folderName,
            url.deletingLastPathComponent().path,
            url.lastPathComponent
        ].joined(separator: " ")
    }
}

private struct NotchSwitchboardService: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let group: String
    let icon: String
    let status: String
    let favorite: Bool
    let priority: Int
    let url: URL?
    let folderPath: String?

    var isFolder: Bool {
        folderPath != nil
    }

    var targetLabel: String {
        if let url {
            return url.absoluteString
        }
        if let folderPath {
            return NSString(string: folderPath).abbreviatingWithTildeInPath
        }
        return "No target"
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return [name, group, status, targetLabel].contains { value in
            value.lowercased().contains(normalized)
        }
    }
}

private enum NotchSwitchboardRegistry {
    static let defaultPath = DeskAgentLocalPaths.servicesRegistryPath

    static func load() -> [NotchSwitchboardService] {
        guard let yaml = try? String(contentsOfFile: defaultPath, encoding: .utf8) else {
            return []
        }

        var records: [[String: String]] = []
        var current: [String: String]?

        for rawLine in yaml.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed != "services:" else { continue }

            if trimmed.hasPrefix("- ") {
                if let current {
                    records.append(current)
                }
                current = [:]
                addKeyValue(String(trimmed.dropFirst(2)), to: &current)
            } else if current != nil {
                addKeyValue(trimmed, to: &current)
            }
        }

        if let current {
            records.append(current)
        }

        return records.enumerated().compactMap { index, record in
            makeService(from: record, index: index + 1)
        }
    }

    private static func addKeyValue(_ line: String, to record: inout [String: String]?) {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalize(String(parts[1]))
        record?[key] = value
    }

    private static func makeService(from record: [String: String], index: Int) -> NotchSwitchboardService? {
        guard let name = nonEmpty(record["name"]) else { return nil }
        let group = nonEmpty(record["group"]) ?? "Ungrouped"
        let icon = nonEmpty(record["icon"]) ?? "circle.grid.2x2"
        let status = nonEmpty(record["status"]) ?? "Ready"
        let favorite = isTruthy(record["favorite"])
        let priority = Int(nonEmpty(record["priority"]) ?? "") ?? 0
        let url = nonEmpty(record["url"]).flatMap { URL(string: $0) }
        let folderPath = nonEmpty(record["folder"]).map { NSString(string: $0).expandingTildeInPath }

        guard url != nil || folderPath != nil else { return nil }

        return NotchSwitchboardService(
            id: slug("\(group)-\(name)-\(index)"),
            name: name,
            group: group,
            icon: icon,
            status: status,
            favorite: favorite,
            priority: priority,
            url: url,
            folderPath: folderPath
        )
    }

    private static func normalize(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["true", "yes", "1"].contains(normalized)
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return value
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private enum NotchSwitchboardHealthChecker {
    static func check(_ services: [NotchSwitchboardService]) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { group in
            for service in services {
                group.addTask {
                    (service.id, await isReachable(service))
                }
            }

            var results: [String: Bool] = [:]
            for await (id, reachable) in group {
                results[id] = reachable
            }
            return results
        }
    }

    private static func isReachable(_ service: NotchSwitchboardService) async -> Bool {
        if let folderPath = service.folderPath {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory)
        }

        guard let url = service.url,
              let host = url.host,
              let port = port(for: url) else {
            return false
        }

        return await canOpenTCP(host: host, port: port)
    }

    private static func port(for url: URL) -> UInt16? {
        if let port = url.port {
            return UInt16(port)
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    private static func canOpenTCP(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let queue = DispatchQueue(label: "markshot.switchboard.health.\(host).\(port)")
            let gate = NotchSwitchboardReachabilityGate()

            let finish: @Sendable (Bool) -> Void = { reachable in
                guard gate.tryFinish() else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.1) {
                finish(false)
            }
        }
    }
}

private final class NotchSwitchboardReachabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

private struct SidecarServerMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let color: Color
    let progress: Double
}

private struct SidecarServerBar: Identifiable {
    let id: String
    let title: String
    let count: Int
    let fraction: Double
    let color: Color
}

private struct SidecarMacSnapshot {
    let runningApps: Int
    let loadAverage: Double
    let diskFreeLabel: String
    let diskFreeFraction: Double

    static func current() -> SidecarMacSnapshot {
        SidecarMacSnapshot(
            runningApps: NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.count,
            loadAverage: currentLoadAverage(),
            diskFreeLabel: diskFreeLabel(),
            diskFreeFraction: diskFreeFraction()
        )
    }

    private static func currentLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return max(0, loads[0])
    }

    private static func diskFreeLabel() -> String {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return "Disk n/a"
        }
        return ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    }

    private static func diskFreeFraction() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity,
              total > 0 else {
            return 0
        }
        return min(1, max(0, Double(available) / Double(total)))
    }
}

private struct SidecarRoomRestore {
    let processIdentifier: pid_t
    let ownerName: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct SidecarUsageWindow: Decodable {
    let calls: Int?
    let input: Int?
    let output: Int?
    let total: Int?
    let estimatedCostUsd: Double?
}

private struct SidecarUsageProvider: Decodable, Identifiable {
    let key: String
    let label: String
    let status: String?
    let sourceLabel: String?
    let callLabel: String?
    let today: SidecarUsageWindow?
    let trailing7: SidecarUsageWindow?
    let trailing30: SidecarUsageWindow?

    var id: String { key }
}

private struct SidecarUsageOverview: Decodable {
    let ok: Bool?
    let today: SidecarUsageWindow?
    let trailing7: SidecarUsageWindow?
    let trailing30: SidecarUsageWindow?
    let providers: [SidecarUsageProvider]?
    let notes: [String]?
    let message: String?
}

private enum NotchMusicScanner {
    static func scan(folderPath: String) -> [NotchMusicTrack] {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let audioExtensions = Set(["aac", "aiff", "aif", "alac", "flac", "m4a", "mp3", "mp4", "wav"])

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if audioExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url)
                if urls.count >= 300 {
                    break
                }
            }
        }

        return urls
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { NotchMusicTrack(url: $0) }
    }
}

@MainActor
private final class HermesChatPopoutController {
    enum DockSide {
        case left
        case right
    }

    private var window: NSPanel?
    private var spawnPosition: CGPoint?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func setSpawnPosition(_ position: CGPoint) {
        self.spawnPosition = position
    }

    func show<Content: View>(rootView: Content) {
        let panel = window ?? makeWindow()
        panel.contentView = NSHostingView(rootView: rootView)
        
        if let pos = spawnPosition {
            let windowSize = panel.frame.size
            let frame = NSRect(
                x: pos.x - windowSize.width / 2,
                y: pos.y - windowSize.height / 2,
                width: windowSize.width,
                height: windowSize.height
            )
            panel.setFrame(frame, display: false)
            self.spawnPosition = nil
        }
        
        if !panel.isVisible {
            panel.alphaValue = 0
            let finalFrame = panel.frame
            let startFrame = finalFrame.insetBy(dx: 15, dy: 15)
            panel.setFrame(startFrame, display: true)
            panel.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
                panel.animator().setFrame(finalFrame, display: true)
            }
        } else {
            panel.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hermes"
        panel.identifier = NSUserInterfaceItemIdentifier("MarkShotHermesPopout")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .black
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.center()
        window = panel
        return panel
    }

    func dock(to side: DockSide) {
        guard let panel = window else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }

        let width = min(max(panel.frame.width, 440), min(520, frame.width * 0.36))
        let x = side == .left ? frame.minX : frame.maxX - width
        let target = NSRect(x: x, y: frame.minY, width: width, height: frame.height)

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}

private struct PopoutCircleButton: View {
    let symbol: String
    let helpText: String
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    private var fontSize: CGFloat {
        isPrimary ? 13 : 12
    }
    
    private var fontWeight: Font.Weight {
        isPrimary ? .black : .bold
    }
    
    private var buttonForeground: Color {
        if isDisabled {
            return Color.white.opacity(0.24)
        }
        if isPrimary {
            return isHovering ? Color.black : Color.black.opacity(0.85)
        }
        return isHovering ? Color.white : Color.white.opacity(0.72)
    }
    
    private var buttonSize: CGFloat {
        isPrimary ? 32 : 28
    }
    
    private var borderOpacity: Double {
        if isPrimary {
            return 0.18
        }
        return isHovering ? 0.15 : 0.07
    }
    
    private var scale: CGFloat {
        isHovering && !isDisabled ? 1.08 : 1.0
    }
    
    private var shadowColor: Color {
        if !isHovering || isDisabled {
            return Color.clear
        }
        if isPrimary {
            return Color(red: 0.32, green: 0.85, blue: 0.75).opacity(0.42)
        }
        return Color.white.opacity(0.08)
    }
    
    private var shadowRadius: CGFloat {
        isHovering ? 6 : 3
    }
    
    @ViewBuilder
    private var buttonBackground: some View {
        if isPrimary {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isHovering 
                            ? [Color(red: 0.34, green: 0.9, blue: 0.8), Color(red: 0.34, green: 0.68, blue: 1.0)]
                            : [Color(red: 0.32, green: 0.85, blue: 0.75), Color(red: 0.34, green: 0.68, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            Circle()
                .fill(isHovering ? Color.white.opacity(0.14) : Color.white.opacity(0.065))
        }
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(buttonForeground)
                .frame(width: buttonSize, height: buttonSize)
                .background(buttonBackground)
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(borderOpacity),
                        lineWidth: 1
                    )
                )
                .scaleEffect(scale)
                .shadow(
                    color: shadowColor,
                    radius: shadowRadius
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(isDisabled)
        .help(helpText)
        .onHover { hovering in
            if !isDisabled {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
        }
    }
}

private struct PopoutComposerField: View {
    @Binding var text: String
    let isSending: Bool
    let onSubmit: () -> Void
    
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    
    private var fieldFillOpacity: Double {
        if isFocused {
            return 0.09
        }
        return isHovering ? 0.075 : 0.05
    }
    
    private var borderAccentColor: Color {
        if isFocused {
            return Color(red: 0.32, green: 0.85, blue: 0.75).opacity(0.4)
        }
        return isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)
    }
    
    private var shadowColor: Color {
        isFocused ? Color(red: 0.32, green: 0.85, blue: 0.75).opacity(0.08) : Color.clear
    }
    
    var body: some View {
        TextField("Message Hermes...", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(Color.white.opacity(fieldFillOpacity))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        borderAccentColor,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: shadowColor,
                radius: 4
            )
            .disabled(isSending)
            .onSubmit(onSubmit)
            .focused($isFocused)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.16)) {
                    isHovering = hovering
                }
            }
    }
}

@MainActor
private final class HermesSidecarWindowController: ObservableObject {
    @Published var isExpanded = false
    @Published var windowHeight: CGFloat = NSScreen.main?.frame.height ?? 900
    private var window: NSPanel?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show<Content: View>(rootView: Content) {
        let panel = window ?? makeWindow()
        let wasVisible = panel.isVisible

        if !wasVisible {
            position(panel)
            isExpanded = true
        }

        if !wasVisible || panel.contentView == nil {
            panel.contentView = NSHostingView(rootView: rootView)
        }

        panel.orderFrontRegardless()

        if !wasVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func toggle() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
            isExpanded.toggle()
        }
        if let window {
            window.orderFrontRegardless()
        }
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
    }

    func previewDrag(deltaX: CGFloat) {
        // Window frame is static; dragging is handled inside the view via bindings
    }

    private func makeWindow() -> NSPanel {
        let panel = HermesSidecarPanel(
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
        window = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let width = Self.windowSize.width
        windowHeight = frame.height
        let target = NSRect(x: frame.maxX - 800, y: frame.minY, width: width, height: frame.height)
        panel.setFrame(target, display: true, animate: false)
    }

    private static let windowSize = CGSize(width: 1000, height: 900)
}

private final class HermesSidecarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum HermesSidecarSection: String, CaseIterable, Identifiable {
    case chat
    case music
    case mac
    case vault
    case servers
    case actions
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .music: return "Music"
        case .mac: return "Mac"
        case .vault: return "Vault"
        case .servers: return "Servers"
        case .actions: return "Actions"
        case .system: return "System"
        }
    }

    var subtitle: String {
        switch self {
        case .chat: return "Same Hermes thread"
        case .music: return "Plex + Spotify"
        case .mac: return "Files and local places"
        case .vault: return "Obsidian notes"
        case .servers: return "Daily control surfaces"
        case .actions: return "Search and automations"
        case .system: return "OS controls"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right.fill"
        case .music: return "music.note"
        case .mac: return "macwindow"
        case .vault: return "books.vertical.fill"
        case .servers: return "server.rack"
        case .actions: return "bolt.fill"
        case .system: return "gearshape.2.fill"
        }
    }

    var accent: Color {
        switch self {
        case .chat: return Color(red: 0.32, green: 0.9, blue: 0.62)
        case .music: return Color(red: 0.75, green: 0.48, blue: 1.0)
        case .mac: return Color(red: 0.34, green: 0.68, blue: 1.0)
        case .vault: return Color(red: 1.0, green: 0.78, blue: 0.36)
        case .servers: return Color(red: 0.98, green: 0.68, blue: 0.08)
        case .actions: return Color(red: 0.32, green: 0.9, blue: 0.9)
        case .system: return Color.white.opacity(0.9)
        }
    }
}

private struct HermesSidecarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var controller: HermesSidecarWindowController
    @Binding var messages: [NotchChatMessage]
    @Binding var draft: String
    @Binding var pendingAttachments: [NotchChatAttachment]
    @Binding var mediaSource: MediaSource
    @Binding var liveReadiness: DeskAgentLiveReadiness?
    @Binding var notchBridgeStatus: DeskAgentNotchStatus?
    @Binding var liveReadinessError: String
    @Binding var isCheckingLiveReadiness: Bool

    let hermesSessionId: String
    let localChatCount: Int
    let persistedChatLimit: Int
    let isSending: Bool
    let thinkingLabel: String
    let onSend: () -> Void
    let onAttachLatest: () -> Void
    let onAttachCapture: () -> Void
    let onAttachClipboard: () -> Void
    let onAddMacContext: () -> Void
    let onMusicControl: (String) -> Void
    let onSelectMediaSource: (MediaSource) -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool
    let onNewChat: () -> Void
    let onArchiveChat: () -> Void
    let onCopyChat: () -> Void
    let onRefreshStatus: () -> Void
    let onToggle: () -> Void

    @State private var activePulse = false
    @State private var activeSection: HermesSidecarSection = .chat
    @State private var sidecarDragOffset: CGFloat = 0
    @State private var sidecarHapticArmed = false
    @State private var sidecarHaptic1 = false
    @State private var sidecarHaptic2 = false
    @State private var sidecarHaptic3 = false
    @State private var macCurrentURL = DeskAgentLocalPaths.homeURL
    @State private var macBackStack: [URL] = []
    @State private var macForwardStack: [URL] = []
    @State private var macEntries: [HermesSidecarFileEntry] = []
    @State private var selectedMacURL: URL?
    @State private var selectedMacURLs: Set<URL> = []
    @State private var macSearch = ""
    @State private var macError: String?
    @State private var macIsLoading = false
    @State private var macLoadID = UUID()
    @State private var macVisibleLimit = 80
    @State private var macTotalEntryCount = 0
    @State private var macFrontmostAppName = "Unknown"
    @State private var macDiskSummary = "Storage unavailable"
    @State private var vaultCurrentURL = DeskAgentLocalPaths.obsidianVaultURL
    @State private var vaultEntries: [HermesSidecarFileEntry] = []
    @State private var selectedVaultURL: URL?
    @State private var vaultSearch = ""
    @State private var vaultError: String?
    @State private var vaultIsLoading = false
    @State private var vaultLoadID = UUID()
    @State private var vaultVisibleLimit = 80
    @State private var vaultNoteText = ""
    @State private var vaultNoteTitle = "Select a note"
    @State private var vaultNoteError: String?
    @State private var vaultNoteIsLoading = false
    @State private var vaultNoteLoadID = UUID()
    @State private var vaultResolvingLink = ""
    @State private var sidecarMusicSource: MediaSource = .spotify
    @State private var sidecarActionSearch = ""
    @State private var sidecarServerSearch = ""
    @State private var sidecarServerServices: [NotchSwitchboardService] = []
    @State private var sidecarServerReachability: [String: Bool] = [:]
    @State private var sidecarServersChecking = false
    @State private var sidecarServersLastChecked: Date?
    @State private var sidecarMacSnapshot = SidecarMacSnapshot.current()
    @State private var sidecarServerPulse = false
    @State private var sidecarRoomRestore: SidecarRoomRestore?
    @State private var sidecarUsageOverview: SidecarUsageOverview?
    @State private var sidecarUsageError = ""
    @State private var sidecarUsageLoading = false
    @State private var sidecarUsageLastChecked: Date?
    @State private var quickLookController: SidecarQuickLookPreviewController?

    private var isExpanded: Bool {
        controller.isExpanded
    }

    var body: some View {
        let rubber = rubberSidecarOffset(sidecarDragOffset)
        
        let sidebarWidth: CGFloat = 438
        let visibleTabWidth: CGFloat = 42
        let windowWidth: CGFloat = 1000
        
        let panelBaseOffset = isExpanded ? 0 : sidebarWidth
        let panelWidth = (isExpanded && rubber < 0) ? (sidebarWidth - rubber) : sidebarWidth
        let panelOffset = (isExpanded && rubber < 0) ? 0 : (panelBaseOffset + rubber)
        
        let tabWidth = isExpanded ? visibleTabWidth : max(visibleTabWidth, visibleTabWidth - rubber * 0.18)
        let tabOffset = isExpanded ? (-sidebarWidth + rubber) : rubber
        
        return ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                sidecarHeader
                Divider().overlay(Color.white.opacity(0.08))
                sidecarSectionSelector
                sidecarContent
            }
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    Color.black.opacity(0.96)
                    RadialGradient(
                        colors: [Color(red: 0.08, green: 0.22, blue: 0.18).opacity(0.24), Color.clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 360
                    )
                }
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 22,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 22,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .offset(x: panelOffset)
            
            sidecarLever(width: tabWidth, rubber: abs(rubber))
                .offset(x: tabOffset)
        }
        .frame(width: 800, alignment: .trailing)
        .frame(width: windowWidth, alignment: .leading)
        .frame(height: max(controller.windowHeight, 600), alignment: .topTrailing)
        .background(Color.clear)
        .onDrop(of: NotchShelfView.chatDropTypes, isTargeted: nil) { providers in
            onDropProviders(providers)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                activePulse = true
            }
        }
    }

    private func sidecarLever(width: CGFloat, rubber: CGFloat) -> some View {
        let gripHeight = 42 + min(rubber * 0.18, 18)
        let gripOpacity = 0.30 + min(rubber / 140.0, 0.24)
        
        let flareHeight: CGFloat = 16
        let tabHeight: CGFloat = 112 + min(rubber * 0.20, 24)
        let totalHeight = tabHeight + flareHeight * 2
        
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(gripOpacity))
                .frame(width: 4, height: gripHeight)
                .offset(x: -width / 2 + 12)
        }
        .frame(width: width, height: tabHeight)
        .background(
            SidecarLeverShape(tabHeight: tabHeight, flareHeight: flareHeight, radius: 16)
                .fill(Color.black.opacity(0.98))
                .frame(width: width, height: totalHeight)
                .overlay(
                    SidecarLeverOutline(tabHeight: tabHeight, flareHeight: flareHeight, radius: 16)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        .frame(width: width, height: totalHeight)
                )
        )
        .shadow(color: Color.black.opacity(0.42), radius: 10 + min(rubber / 10.0, 6), y: 3)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(sidecarPullGesture)
        .help("Slide Hermes sidecar")
    }
 
    private var sidecarPullGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                let translation = value.translation
                let allowed = isExpanded ? translation.width : min(0, translation.width)
                sidecarDragOffset = allowed
                let rubber = rubberSidecarOffset(allowed)
                
                let stretch = abs(rubber)
                
                if stretch > 40.0 && stretch <= 80.0 && !sidecarHaptic1 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    sidecarHaptic1 = true
                }
                if stretch > 80.0 && stretch <= 120.0 && !sidecarHaptic2 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    sidecarHaptic2 = true
                }
                if stretch > 120.0 && !sidecarHaptic3 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                    sidecarHaptic3 = true
                }
                
                if stretch < 120.0 { sidecarHaptic3 = false }
                if stretch < 80.0 { sidecarHaptic2 = false }
                if stretch < 40.0 { sidecarHaptic1 = false }
            }
            .onEnded { value in
                let translation = value.translation
                let allowed = isExpanded ? translation.width : min(0, translation.width)
                let rubber = rubberSidecarOffset(allowed)
                
                // Toggle if tapped (very small drag distance)
                if abs(translation.width) < 5 && abs(translation.height) < 5 {
                    toggleSidecarWithHaptic()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                        sidecarDragOffset = 0
                    }
                    sidecarHaptic1 = false
                    sidecarHaptic2 = false
                    sidecarHaptic3 = false
                    return
                }
                
                if !isExpanded {
                    if rubber < -40.0 {
                        controller.isExpanded = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                    } else {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    }
                } else {
                    if rubber > 40.0 {
                        controller.isExpanded = false
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                    } else if rubber < -60.0 {
                        controller.isExpanded = false
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                    } else {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    }
                }
                
                withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                    sidecarDragOffset = 0
                }
                sidecarHaptic1 = false
                sidecarHaptic2 = false
                sidecarHaptic3 = false
            }
    }

    private func toggleSidecarWithHaptic() {
        controller.isExpanded.toggle()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func rubberSidecarOffset(_ offset: CGFloat) -> CGFloat {
        guard offset != 0 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        let distance = abs(offset)
        return sign * (distance / (1.0 + distance / 120.0))
    }

    private var sidecarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: activeSection.symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.62))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes Sidecar")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Text(activeSection.subtitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
            }
            Spacer(minLength: 0)
            PopoutCircleButton(
                symbol: sidecarRoomRestore == nil ? "rectangle.split.2x1.fill" : "arrow.uturn.backward",
                helpText: sidecarRoomRestore == nil ? "Make room for sidecar" : "Restore \(sidecarRoomRestore?.ownerName ?? "window")",
                isPrimary: false,
                isDisabled: false,
                action: toggleRoomForSidecar
            )
                PopoutCircleButton(
                    symbol: "paperclip",
                    helpText: "Attach files or folders",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachLatest
            )
            PopoutCircleButton(
                symbol: "chevron.right",
                helpText: "Tuck sidecar",
                isPrimary: false,
                isDisabled: false,
                action: onToggle
            )
        }
        .padding(.top, 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var sidecarSectionSelector: some View {
        HStack(spacing: 13) {
            ForEach(HermesSidecarSection.allCases) { section in
                SidecarSectionButton(
                    section: section,
                    isSelected: activeSection == section
                ) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        activeSection = section
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.74))
    }

    @ViewBuilder
    private var sidecarContent: some View {
        switch activeSection {
        case .chat:
            VStack(spacing: 0) {
                sidecarChatSessionBar
                sidecarMessages
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                sidecarComposer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.84))
        case .music:
            sidecarMusicBrowser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .mac:
            sidecarMacBrowser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .vault:
            sidecarVaultBrowser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .servers:
            sidecarServerDashboard
        case .actions:
            sidecarActionsDashboard
        case .system:
            sidecarActionList(rows: systemRows)
        }
    }

    private var sidecarChatSessionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(red: 0.62, green: 0.82, blue: 1.0))
            Text(sidecarChatSessionSummary)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
            Spacer(minLength: 0)
            PopoutCircleButton(symbol: "archivebox", helpText: "Archive visible chat to Obsidian", isPrimary: false, isDisabled: false, action: onArchiveChat)
            PopoutCircleButton(symbol: "doc.on.doc", helpText: "Copy visible chat transcript", isPrimary: false, isDisabled: false, action: onCopyChat)
            PopoutCircleButton(symbol: "plus", helpText: "Start a new Hermes session", isPrimary: false, isDisabled: false, action: onNewChat)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color.black.opacity(0.82).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom))
    }

    private var sidecarChatSessionSummary: String {
        let visible = min(localChatCount, persistedChatLimit)
        let trimmed = hermesSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "New Hermes session; visible chat is local"
        }
        return "Visible last \(visible); Hermes session \(String(trimmed.prefix(8))) keeps context"
    }

    private var sidecarMessages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(messages) { message in
                        sidecarBubble(message)
                            .id(message.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(thinkingLabel)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(activePulse ? 0.72 : 0.34))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(activePulse ? 0.055 : 0.025), in: Capsule())
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _ in
                scrollSidecarToLatest(proxy, animated: true)
            }
            .onAppear {
                scrollSidecarToLatest(proxy, animated: false)
                DispatchQueue.main.async {
                    scrollSidecarToLatest(proxy, animated: false)
                }
            }
        }
    }

    private func scrollSidecarToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var sidecarActionsDashboard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.62))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.07), in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Actions")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.86))
                        Text("Search commands, views, and automations")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                    TextField("Search actions...", text: $sidecarActionSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    if !sidecarActionSearch.isEmpty {
                        Button {
                            sidecarActionSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.34))
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            }
            .padding(16)
            .background(Color.black.opacity(0.84))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    sidecarSystemStateCard
                    sidecarUsageCard

                    if filteredActionRows.isEmpty {
                        Text("No matching actions.")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredActionRows) { row in
                            sidecarActionRow(row)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.84))
        .onAppear {
            if sidecarUsageOverview == nil, !sidecarUsageLoading {
                refreshSidecarUsage()
            }
        }
    }

    private var sidecarSystemStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(sidecarLiveHealthColor)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.07), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("System State")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                    Text(sidecarSystemStateSubtitle)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh system state",
                    isPrimary: false,
                    isDisabled: isCheckingLiveReadiness,
                    action: onRefreshStatus
                )
            }

            HStack(spacing: 8) {
                sidecarHealthPill(title: "Hermes", detail: sidecarHermesDetail, color: sidecarHermesHealthColor)
                sidecarHealthPill(title: "Live", detail: sidecarLiveDetail, color: sidecarLiveHealthColor)
                sidecarHealthPill(title: "Phone", detail: sidecarPhoneDetail, color: sidecarPhoneHealthColor)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func sidecarHealthPill(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }
            Text(detail)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sidecarHermesHealthColor: Color {
        isSending ? Color(red: 0.62, green: 0.82, blue: 1.0) : Color(red: 0.32, green: 0.9, blue: 0.62)
    }

    private var sidecarLiveHealthColor: Color {
        if isCheckingLiveReadiness {
            return Color(red: 0.62, green: 0.82, blue: 1.0)
        }
        if !liveReadinessError.isEmpty {
            return .orange
        }
        if liveReadiness?.isReady == true {
            return Color(red: 0.32, green: 0.9, blue: 0.62)
        }
        return .white.opacity(0.32)
    }

    private var sidecarPhoneHealthColor: Color {
        if (notchBridgeStatus?.pairedDevices ?? 0) > 0 {
            return .white.opacity(0.34)
        }
        if !liveReadinessError.isEmpty {
            return .orange
        }
        return .white.opacity(0.32)
    }

    private var sidecarHermesDetail: String {
        isSending ? "answering" : "text ready"
    }

    private var sidecarLiveDetail: String {
        if isCheckingLiveReadiness { return "checking" }
        if !liveReadinessError.isEmpty { return "helper off" }
        if liveReadiness?.isReady == true { return "ready" }
        return "unknown"
    }

    private var sidecarPhoneDetail: String {
        if let count = notchBridgeStatus?.pairedDevices, count > 0 {
            return count == 1 ? "saved" : "\(count) saved"
        }
        if !liveReadinessError.isEmpty { return "helper off" }
        return "not saved"
    }

    private var sidecarSystemStateSubtitle: String {
        if isSending {
            return "Hermes is answering in the shared thread."
        }
        if !liveReadinessError.isEmpty {
            return "Hermes text works; Live, phone, and AirSend need helper."
        }
        if liveReadiness?.isReady == true {
            return (notchBridgeStatus?.pairedDevices ?? 0) > 0 ? "Hermes and Live are ready; a phone pairing is saved." : "Hermes and Live are ready; no phone pairing is saved."
        }
        if isCheckingLiveReadiness {
            return "Checking Live and phone helper."
        }
        return "Hermes text is local; helper state has not been checked."
    }

    private var sidecarUsageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.9))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.07), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                    Text(sidecarUsageSubtitle)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh usage",
                    isPrimary: false,
                    isDisabled: sidecarUsageLoading,
                    action: refreshSidecarUsage
                )
                PopoutCircleButton(
                    symbol: "arrow.up.forward.app",
                    helpText: "Open Hermes cockpit",
                    isPrimary: false,
                    isDisabled: false,
                    action: { openURLString("http://127.0.0.1:3217") }
                )
            }

            if sidecarUsageLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking cockpit usage...")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                    Spacer(minLength: 0)
                }
            } else if let usage = sidecarUsageOverview, usage.ok != false {
                HStack(spacing: 8) {
                    sidecarUsageMetric("Today", value: Self.compactNumber(usage.today?.total ?? 0), detail: "\(usage.today?.calls ?? 0) records")
                    sidecarUsageMetric("7 days", value: Self.compactNumber(usage.trailing7?.total ?? 0), detail: "\(trackedUsageProviderCount(usage)) sources")
                    sidecarUsageMetric("Est.", value: sidecarUsageCostLabel(usage), detail: "metered")
                }

                if let providers = usage.providers, !providers.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(providers.prefix(4)) { provider in
                            Text(provider.label)
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .foregroundStyle((provider.status == "tracked") ? Color.black.opacity(0.78) : .white.opacity(0.48))
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background((provider.status == "tracked") ? Color(red: 0.32, green: 0.9, blue: 0.62) : Color.white.opacity(0.055), in: Capsule())
                        }
                    }
                }
            } else {
                Text(sidecarUsageError.isEmpty ? "Cockpit usage is offline. Open Hermes cockpit to start the source." : sidecarUsageError)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
    }

    private func sidecarUsageMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
            Text(value)
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sidecarUsageSubtitle: String {
        if sidecarUsageLoading { return "checking cockpit" }
        if sidecarUsageOverview?.ok == true {
            if let date = sidecarUsageLastChecked {
                return "updated \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "cockpit usage snapshot"
        }
        return "cockpit offline"
    }

    private func refreshSidecarUsage() {
        sidecarUsageLoading = true
        sidecarUsageError = ""

        Task {
            do {
                guard let url = URL(string: "http://127.0.0.1:3217/api/usage/overview") else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                let (data, _) = try await URLSession.shared.data(for: request)
                let overview = try JSONDecoder().decode(SidecarUsageOverview.self, from: data)
                await MainActor.run {
                    sidecarUsageOverview = overview
                    sidecarUsageLastChecked = Date()
                    sidecarUsageLoading = false
                    sidecarUsageError = overview.message ?? ""
                }
            } catch {
                await MainActor.run {
                    sidecarUsageOverview = nil
                    sidecarUsageLoading = false
                    sidecarUsageError = "Cockpit usage is offline."
                }
            }
        }
    }

    private func trackedUsageProviderCount(_ usage: SidecarUsageOverview) -> Int {
        (usage.providers ?? []).filter { $0.status == "tracked" }.count
    }

    private func sidecarUsageCostLabel(_ usage: SidecarUsageOverview) -> String {
        let cost = (usage.providers ?? []).reduce(0.0) { total, provider in
            total + (provider.trailing7?.estimatedCostUsd ?? 0)
        }
        guard cost > 0 else { return "--" }
        return Self.compactUsd(cost)
    }

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private static func compactUsd(_ value: Double) -> String {
        "$" + String(format: value >= 100 ? "%.0f" : "%.2f", value)
    }

    private var sidecarComposer: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            sidecarPendingAttachmentPill(attachment)
                        }
                    }
                }
                .frame(height: 22)
            }

            HStack(spacing: 8) {
                PopoutCircleButton(
                    symbol: pendingAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill",
                    helpText: pendingAttachments.isEmpty ? "Attach files or folders" : "\(pendingAttachments.count) attached",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachLatest
                )
                PopoutCircleButton(
                    symbol: "photo.on.rectangle",
                    helpText: "Attach latest capture",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachCapture
                )
                PopoutCircleButton(
                    symbol: "doc.on.clipboard",
                    helpText: "Add clipboard to chat",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachClipboard
                )
                PopoutCircleButton(
                    symbol: "macwindow",
                    helpText: "Add current Mac app context",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAddMacContext
                )
                TextField("Message Hermes...", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.065), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .onSubmit(onSend)
                    .disabled(isSending)
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty
                PopoutCircleButton(
                    symbol: "arrow.up",
                    helpText: empty ? "Type or attach something" : "Send message",
                    isPrimary: !empty,
                    isDisabled: empty || isSending,
                    action: onSend
                )
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.9).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .top))
    }

    private func sidecarPendingAttachmentPill(_ attachment: NotchChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(attachment.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
            Button {
                pendingAttachments.removeAll { $0.id == attachment.id || $0.url == attachment.url }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.58))
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.white.opacity(0.035), in: Capsule())
    }

    private func sidecarActionList(rows: [HermesSidecarActionRow]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 10) {
                ForEach(rows) { row in
                    sidecarActionRow(row)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.84))
    }

    private func sidecarActionRow(_ row: HermesSidecarActionRow) -> some View {
        Button {
            row.action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(row.accent)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(row.subtitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
    }

    private var sidecarMusicBrowser: some View {
        VStack(spacing: 0) {
            sidecarMusicHeader
            ZStack {
                Color.black.opacity(0.82)
                MusicBrowserWebView(desiredSource: sidecarMusicSource, state: state)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.84))
    }

    private var sidecarMusicHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([MediaSource.spotify, .plex], id: \.rawValue) { source in
                    sidecarMusicSourceButton(source)
                }
            }

            HStack(spacing: 10) {
                PopoutCircleButton(symbol: "shuffle", helpText: "Shuffle", isPrimary: false, isDisabled: false) {
                    runSidecarMusicControl("shuffle")
                }
                PopoutCircleButton(symbol: "backward.fill", helpText: "Previous", isPrimary: false, isDisabled: false) {
                    runSidecarMusicControl("previous track")
                }
                PopoutCircleButton(symbol: state.notchPlaybackActive ? "pause.fill" : "play.fill", helpText: state.notchPlaybackActive ? "Pause" : "Play", isPrimary: true, isDisabled: false) {
                    runSidecarMusicControl("playpause")
                }
                PopoutCircleButton(symbol: "forward.fill", helpText: "Next", isPrimary: false, isDisabled: false) {
                    runSidecarMusicControl("next track")
                }
                PopoutCircleButton(symbol: "repeat", helpText: "Repeat", isPrimary: false, isDisabled: false) {
                    runSidecarMusicControl("repeat")
                }
                Spacer(minLength: 0)
                PopoutCircleButton(symbol: "arrow.up.forward.app", helpText: "Open in browser", isPrimary: false, isDisabled: false) {
                    openURLString(sidecarMusicWebURL)
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.86).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom))
    }

    private func sidecarMusicSourceButton(_ source: MediaSource) -> some View {
        let isSelected = sidecarMusicSource == source
        let foreground = isSelected ? Color.black.opacity(0.86) : Color.white.opacity(0.58)
        let background = isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.055)

        return Button {
            if sidecarMusicSource == source {
                onSelectMediaSource(source)
                return
            }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                sidecarMusicSource = source
                mediaSource = source
            }
            onSelectMediaSource(source)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sidecarMusicSymbol(source))
                    .font(.system(size: 10, weight: .black))
                Text(sidecarMusicTitle(source))
                    .font(.system(size: 10, weight: .black, design: .rounded))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
    }

    private func runSidecarMusicControl(_ command: String) {
        if mediaSource != sidecarMusicSource {
            mediaSource = sidecarMusicSource
            onSelectMediaSource(sidecarMusicSource)
        }
        onMusicControl(command)
    }

    private var sidecarServerDashboard: some View {
        VStack(spacing: 0) {
            sidecarServerHeader
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    sidecarServerMetricGrid
                    sidecarServerActivityPanel
                    sidecarServerList
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.84))
        .onAppear {
            loadSidecarServers()
            refreshSidecarDashboardSnapshot()
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                sidecarServerPulse = true
            }
        }
    }

    private var sidecarServerHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sidecarServerHeadline)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(sidecarServerSubheadline)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh server status",
                    isPrimary: false,
                    isDisabled: sidecarServersChecking,
                    action: refreshSidecarServers
                )
                PopoutCircleButton(
                    symbol: "doc.text.magnifyingglass",
                    helpText: "Open service registry",
                    isPrimary: false,
                    isDisabled: false,
                    action: { openPath(NotchSwitchboardRegistry.defaultPath) }
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                TextField("Search services", text: $sidecarServerSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                if !sidecarServerSearch.isEmpty {
                    Button {
                        sidecarServerSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    .buttonStyle(NotchPressButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
        }
        .padding(16)
        .background(Color.black.opacity(0.78).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom))
    }

    private var sidecarServerMetricGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(sidecarServerMetrics) { metric in
                sidecarServerMetricCard(metric)
            }
        }
    }

    private var sidecarServerActivityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(red: 0.65, green: 0.82, blue: 1.0))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Network shape")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Local, LAN, admin, and cloud surfaces from Switchboard")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(sidecarServersChecking ? Color(red: 0.65, green: 0.82, blue: 1.0) : Color(red: 0.32, green: 0.9, blue: 0.62))
                    .frame(width: 7, height: 7)
                    .scaleEffect(sidecarServerPulse ? 1.35 : 0.85)
                    .opacity(sidecarServerPulse ? 0.55 : 1.0)
            }

            HStack(alignment: .bottom, spacing: 7) {
                ForEach(sidecarServerBars) { bar in
                    VStack(spacing: 5) {
                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.white.opacity(0.055))
                            Capsule()
                                .fill(bar.color.opacity(0.86))
                                .frame(height: max(10, 58 * bar.fraction))
                        }
                        .frame(height: 58)
                        Text(bar.title)
                            .font(.system(size: 7, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                        Text("\(bar.count)")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: sidecarServerBars.map(\.count))
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.065), lineWidth: 1))
    }

    private var sidecarServerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Switchboard")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 0)
                Text("\(filteredSidecarServers.count)")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            ScrollView(.vertical, showsIndicators: true) {
                sidecarServerRows
                    .padding(.trailing, 2)
            }
            .frame(maxHeight: 210)
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.055), lineWidth: 1))
    }

    private var sidecarServerRows: some View {
        LazyVStack(spacing: 6) {
            if sidecarServerServices.isEmpty {
                Text("No services loaded from SERVICES.yaml.")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if filteredSidecarServers.isEmpty {
                Text("No matching services.")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ForEach(filteredSidecarServers) { service in
                    sidecarServerRow(service)
                }
            }
        }
    }

    private func sidecarServerMetricCard(_ metric: SidecarServerMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(metric.color)
                    .frame(width: 22, height: 22)
                    .background(metric.color.opacity(0.14), in: Circle())
                Spacer(minLength: 0)
                Text(metric.title)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Text(metric.value)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(metric.subtitle)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(metric.color.opacity(0.82))
                        .frame(width: max(8, proxy.size.width * min(1, max(0, metric.progress))))
                }
            }
            .frame(height: 4)
        }
        .padding(11)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.065), lineWidth: 1))
    }

    private func sidecarServerRow(_ service: NotchSwitchboardService) -> some View {
        Button {
            openSidecarServer(service)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(sidecarServerDotColor(service))
                    .frame(width: 7, height: 7)
                Image(systemName: service.icon)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    Text("\(service.group)  \(service.status)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(sidecarServerStateLabel(service))
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(sidecarServerDotColor(service).opacity(0.9))
                    .lineLimit(1)
                Image(systemName: service.isFolder ? "folder" : "arrow.up.forward")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(service.favorite ? 0.058 : 0.038), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.055), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(service.targetLabel)
    }

    private var sidecarMacBrowser: some View {
        VStack(spacing: 0) {
            macControlStrip
            macBrowserToolbar
            if let macError {
                Text(macError)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            macEntryList
            macSelectionBar
        }
        .background(Color.black.opacity(0.84))
        .onAppear {
            refreshMacControlStrip()
            reloadMacEntries()
        }
        .onChange(of: macCurrentURL) { _ in
            reloadMacEntries()
        }
    }

    private var macControlStrip: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This Mac")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Frontmost: \(macFrontmostAppName)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                    Text(macDiskSummary)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh Mac status",
                    isPrimary: false,
                    isDisabled: false,
                    action: refreshMacControlStrip
                )
            }

            HStack(spacing: 8) {
                macQuickAction(title: "Finder", symbol: "face.smiling", path: "/System/Library/CoreServices/Finder.app")
                macQuickAction(title: "Terminal", symbol: "terminal", path: "/System/Applications/Utilities/Terminal.app")
                macQuickAction(title: "Monitor", symbol: "waveform.path.ecg", path: "/System/Applications/Utilities/Activity Monitor.app")
                macQuickAction(title: "Settings", symbol: "gearshape.fill", path: "/System/Applications/System Settings.app")
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.82).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom))
    }

    private func macQuickAction(title: String, symbol: String, path: String) -> some View {
        Button {
            openPath(path)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white.opacity(0.74))
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.44))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.white.opacity(0.052), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("Open \(title)")
    }

    private var macBrowserToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                PopoutCircleButton(
                    symbol: "chevron.backward",
                    helpText: "Back",
                    isPrimary: false,
                    isDisabled: macBackStack.isEmpty,
                    action: goBackMacFolder
                )
                PopoutCircleButton(
                    symbol: "chevron.forward",
                    helpText: "Forward",
                    isPrimary: false,
                    isDisabled: macForwardStack.isEmpty,
                    action: goForwardMacFolder
                )
                PopoutCircleButton(
                    symbol: "arrow.up",
                    helpText: "Up one folder",
                    isPrimary: false,
                    isDisabled: macCurrentURL.path == "/",
                    action: openParentMacFolder
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(macCurrentURL.lastPathComponent.isEmpty ? macCurrentURL.path : macCurrentURL.lastPathComponent)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                    Text(macCurrentURL.path)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh folder",
                    isPrimary: false,
                    isDisabled: false,
                    action: reloadMacEntries
                )
                PopoutCircleButton(
                    symbol: "arrow.up.forward.square",
                    helpText: "Reveal current folder",
                    isPrimary: false,
                    isDisabled: false,
                    action: revealCurrentMacFolder
                )
                PopoutCircleButton(
                    symbol: "terminal",
                    helpText: "Terminal here",
                    isPrimary: false,
                    isDisabled: false,
                    action: openTerminalAtCurrentMacFolder
                )
            }
            macBreadcrumbBar
            HStack(spacing: 6) {
                ForEach(macRootButtons) { root in
                    Button {
                        guard !macIsLoading else { return }
                        navigateMacFolder(to: root.url)
                    } label: {
                        Image(systemName: root.symbol)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(macCurrentURL.path == root.url.path ? Color.black.opacity(0.82) : .white.opacity(0.54))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(macCurrentURL.path == root.url.path ? Color.white.opacity(0.88) : Color.white.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .help(root.title)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                TextField("Search this folder", text: $macSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                if !macSearch.isEmpty {
                    Button {
                        macSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    .buttonStyle(NotchPressButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
        }
        .padding(16)
        .background(Color.black.opacity(0.72))
    }

    private var macBreadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(macBreadcrumbItems) { item in
                    Button {
                        navigateMacFolder(to: item.url)
                    } label: {
                        HStack(spacing: 4) {
                            if item.isRoot {
                                Image(systemName: "internaldrive.fill")
                                    .font(.system(size: 8, weight: .black))
                            }
                            Text(item.title)
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .lineLimit(1)
                            if !item.isLast {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundStyle(.white.opacity(0.26))
                            }
                        }
                        .foregroundStyle(item.isLast ? Color.black.opacity(0.82) : .white.opacity(0.52))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(item.isLast ? Color.white.opacity(0.86) : Color.white.opacity(0.052), in: Capsule())
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .help(item.url.path)
                }
            }
        }
    }

    private var macEntryList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 7) {
                if macIsLoading {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loading folder")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                            Text(macCurrentURL.path)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.32))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if filteredMacEntries.isEmpty {
                    Text(macSearch.isEmpty ? "No visible files here." : "No matches in this folder.")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ForEach(filteredMacEntries) { entry in
                        macEntryRow(entry)
                    }
                    if canShowMoreMacEntries {
                        Button {
                            macVisibleLimit += 80
                        } label: {
                            Text("Show more")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(NotchPressButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: NotchShelfView.chatDropTypes, isTargeted: nil) { providers in
            handleMacFolderDrop(providers)
        }
    }

    private var macSelectionBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(macSelectionTitle)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(macSelectionSubtitle)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PopoutCircleButton(
                symbol: "plus",
                helpText: "New folder",
                isPrimary: false,
                isDisabled: false,
                action: createMacFolder
            )
            PopoutCircleButton(
                symbol: "doc.badge.plus",
                helpText: "New file",
                isPrimary: false,
                isDisabled: false,
                action: createMacFile
            )
            PopoutCircleButton(
                symbol: "eye",
                helpText: "Quick Look selected file",
                isPrimary: false,
                isDisabled: selectedPreviewableMacURL == nil,
                action: previewSelectedMacFile
            )
            .keyboardShortcut(.space, modifiers: [])
            PopoutCircleButton(
                symbol: "info.circle",
                helpText: "Get info",
                isPrimary: false,
                isDisabled: selectedMacURLs.count != 1,
                action: showSelectedMacItemInfo
            )
            PopoutCircleButton(
                symbol: "doc.on.doc",
                helpText: "Copy selected paths",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: copySelectedMacPaths
            )
            PopoutCircleButton(
                symbol: "doc.on.clipboard",
                helpText: "Paste files here",
                isPrimary: false,
                isDisabled: false,
                action: pasteMacFilesHere
            )
            PopoutCircleButton(
                symbol: "paperclip",
                helpText: "Attach selected to Hermes",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: attachSelectedMacItems
            )
            PopoutCircleButton(
                symbol: "archivebox",
                helpText: "Zip selected",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: zipSelectedMacItems
            )
            PopoutCircleButton(
                symbol: "square.on.square",
                helpText: "Duplicate selected here",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: duplicateSelectedMacItems
            )
            PopoutCircleButton(
                symbol: "folder.badge.plus",
                helpText: "Move selected to folder",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: moveSelectedMacItems
            )
            PopoutCircleButton(
                symbol: "pencil",
                helpText: "Rename selected item",
                isPrimary: false,
                isDisabled: selectedMacURLs.count != 1,
                action: renameSelectedMacItem
            )
            PopoutCircleButton(
                symbol: "trash",
                helpText: "Move selected to Trash",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: trashSelectedMacItems
            )
            PopoutCircleButton(
                symbol: "arrow.up.forward",
                helpText: "Open selected item",
                isPrimary: false,
                isDisabled: selectedMacURLs.count != 1,
                action: openSelectedMacItem
            )
            PopoutCircleButton(
                symbol: "folder",
                helpText: "Reveal selected item",
                isPrimary: false,
                isDisabled: selectedMacURLs.isEmpty,
                action: revealSelectedMacItem
            )
        }
        .padding(16)
        .background(Color.black.opacity(0.9).overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .top))
    }

    private func refreshMacControlStrip() {
        macFrontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        macDiskSummary = Self.diskSummary(for: URL(fileURLWithPath: "/"))
    }

    private func macEntryRow(_ entry: HermesSidecarFileEntry) -> some View {
        let isSelected = selectedMacURLs.contains(entry.url)

        return HStack(spacing: 8) {
            Button {
                toggleMacSelection(entry.url)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(isSelected ? Color(red: 0.32, green: 0.9, blue: 0.62) : .white.opacity(0.24))
                    Image(systemName: entry.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(entry.isDirectory ? Color(red: 0.34, green: 0.68, blue: 1.0) : .white.opacity(0.68))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                        Text(entry.subtitle)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.34))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    isSelected ? Color.white.opacity(0.105) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color(red: 0.32, green: 0.9, blue: 0.62).opacity(0.55) : Color.white.opacity(0.055), lineWidth: 1)
                )
            }
            .buttonStyle(NotchPressButtonStyle())

            if entry.isDirectory {
                Button {
                    openMacFolder(entry.url)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.055), in: Circle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .help("Open folder")
            }
        }
        .onDrag {
            NSItemProvider(object: entry.url as NSURL)
        }
        .contextMenu {
            if entry.isDirectory {
                Button("Open Folder") {
                    openMacFolder(entry.url)
                }
            }
            Button(isSelected ? "Deselect" : "Select") {
                toggleMacSelection(entry.url)
            }
            Button("Open") {
                NSWorkspace.shared.open(entry.url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            if !entry.isDirectory {
                Button("Quick Look") {
                    previewMacFile(entry.url)
                }
            }
            Button("Get Info") {
                showMacItemInfo(entry.url)
            }
            Button("Copy Path") {
                copyMacPaths([entry.url])
            }
            Button("Copy File") {
                copyMacFilesToPasteboard([entry.url])
            }
            Button("Duplicate Here") {
                duplicateMacItems([entry.url])
            }
            Button("Move to Folder...") {
                moveMacItems([entry.url])
            }
            Button("Attach to Hermes") {
                attachMacItems([entry.url])
            }
            Button("Zip") {
                zipMacItems([entry.url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                trashMacItems([entry.url])
            }
        }
    }

    private var sidecarVaultBrowser: some View {
        VStack(spacing: 0) {
            vaultBrowserToolbar
            if let vaultError {
                Text(vaultError)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            vaultEntryList
            Divider().overlay(Color.white.opacity(0.08))
            vaultPreviewPane
        }
        .background(Color.black.opacity(0.84))
        .onAppear(perform: reloadVaultEntries)
        .onChange(of: vaultCurrentURL) { _ in
            reloadVaultEntries()
        }
    }

    private var vaultBrowserToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                PopoutCircleButton(
                    symbol: "chevron.left",
                    helpText: "Up one vault folder",
                    isPrimary: false,
                    isDisabled: vaultCurrentURL.path == Self.obsidianVaultURL.path,
                    action: openParentVaultFolder
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(vaultCurrentURL.path == Self.obsidianVaultURL.path ? "1note Vault" : vaultCurrentURL.lastPathComponent)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                    Text(vaultRelativePath(vaultCurrentURL))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "arrow.clockwise",
                    helpText: "Refresh vault folder",
                    isPrimary: false,
                    isDisabled: false,
                    action: reloadVaultEntries
                )
            }
            HStack(spacing: 6) {
                ForEach(vaultRootButtons) { root in
                    Button {
                        guard !vaultIsLoading else { return }
                        vaultCurrentURL = root.url
                        selectedVaultURL = nil
                        vaultSearch = ""
                        vaultVisibleLimit = 80
                    } label: {
                        Text(root.title)
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(vaultCurrentURL.path == root.url.path ? Color.black.opacity(0.82) : .white.opacity(0.54))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(vaultCurrentURL.path == root.url.path ? Color.white.opacity(0.88) : Color.white.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(NotchPressButtonStyle())
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                TextField("Search notes here", text: $vaultSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                if !vaultSearch.isEmpty {
                    Button {
                        vaultSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    .buttonStyle(NotchPressButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
        }
        .padding(16)
        .background(Color.black.opacity(0.72))
    }

    private var vaultEntryList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 7) {
                if vaultIsLoading {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loading vault")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                            Text(vaultRelativePath(vaultCurrentURL))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.32))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if filteredVaultEntries.isEmpty {
                    Text(vaultSearch.isEmpty ? "No notes in this folder." : "No matching notes here.")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ForEach(filteredVaultEntries) { entry in
                        vaultEntryRow(entry)
                    }
                    if canShowMoreVaultEntries {
                        Button {
                            vaultVisibleLimit += 80
                        } label: {
                            Text("Show more")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(NotchPressButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: 210)
    }

    private var vaultPreviewPane: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(vaultNoteTitle)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                    Text(selectedVaultURL.map(vaultRelativePath(_:)) ?? "Open a markdown note inside the sidecar")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "arrow.up.forward.app",
                    helpText: "Open in Obsidian",
                    isPrimary: false,
                    isDisabled: selectedVaultURL == nil,
                    action: openSelectedVaultNoteInObsidian
                )
                PopoutCircleButton(
                    symbol: "folder",
                    helpText: "Reveal note",
                    isPrimary: false,
                    isDisabled: selectedVaultURL == nil,
                    action: revealSelectedVaultNote
                )
            }
            if vaultNoteIsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading note")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let vaultNoteError {
                Text(vaultNoteError)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.48))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(vaultPreviewAttributedText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(vaultNoteText.isEmpty ? 0.34 : 0.72))
                        .tint(Color(red: 0.32, green: 0.9, blue: 0.62))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 12)
                }
                .environment(\.openURL, OpenURLAction { url in
                    handleVaultPreviewLink(url)
                })
            }
            if !vaultResolvingLink.isEmpty {
                Text(vaultResolvingLink)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.62).opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }

    private func vaultEntryRow(_ entry: HermesSidecarFileEntry) -> some View {
        Button {
            if entry.isDirectory {
                vaultCurrentURL = entry.url
                selectedVaultURL = nil
                vaultSearch = ""
                vaultNoteTitle = "Select a note"
                vaultNoteText = ""
                vaultNoteError = nil
            } else {
                selectedVaultURL = entry.url
                loadVaultNote(entry.url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(entry.isDirectory ? Color(red: 0.34, green: 0.68, blue: 1.0) : Color(red: 0.32, green: 0.9, blue: 0.62))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayNameWithoutExtension)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    Text(entry.isDirectory ? "Folder" : entry.subtitle)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: entry.isDirectory ? "chevron.right" : "text.page")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                selectedVaultURL == entry.url ? Color.white.opacity(0.105) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selectedVaultURL == entry.url ? Color(red: 0.32, green: 0.9, blue: 0.62).opacity(0.55) : Color.white.opacity(0.055), lineWidth: 1)
            )
        }
        .buttonStyle(NotchPressButtonStyle())
    }

    private func sidecarBubble(_ message: NotchChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(message.role == .user ? Color.black.opacity(0.84) : .white.opacity(0.76))
                    .textSelection(.enabled)
                if let source = message.source, !source.isEmpty {
                    Text(source == "iphone" ? "phone" : source)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(message.role == .user ? Color.black.opacity(0.42) : Color(red: 0.32, green: 0.9, blue: 0.62))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                message.role == .user ? Color.white.opacity(0.88) : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            if message.role != .user { Spacer(minLength: 48) }
        }
    }

    private var filteredMacEntries: [HermesSidecarFileEntry] {
        let trimmed = macSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = trimmed.isEmpty ? macEntries : macEntries.filter { $0.name.lowercased().contains(trimmed) }
        return Array(filtered.prefix(macVisibleLimit))
    }

    private var sidecarMusicWebURL: String {
        musicBrowseWebURL(for: sidecarMusicSource)
    }

    private func sidecarMusicTitle(_ source: MediaSource) -> String {
        switch source {
        case .spotify:
            return "Spotify"
        case .plex:
            return "Plex"
        case .music:
            return "Music"
        }
    }

    private func sidecarMusicSymbol(_ source: MediaSource) -> String {
        switch source {
        case .spotify:
            return "music.note"
        case .plex:
            return "play.tv.fill"
        case .music:
            return "music.quarternote.3"
        }
    }

    private var filteredSidecarServers: [NotchSwitchboardService] {
        let trimmed = sidecarServerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = sidecarServerServices.sorted { left, right in
            if left.priority != right.priority { return left.priority > right.priority }
            if left.favorite != right.favorite { return left.favorite && !right.favorite }
            if left.group != right.group { return left.group < right.group }
            return left.name < right.name
        }
        guard !trimmed.isEmpty else { return services }
        return services.filter { $0.matches(trimmed) }
    }

    private var sidecarServerMetrics: [SidecarServerMetric] {
        let total = max(1, sidecarServerServices.count)
        let reachable = sidecarServerReachability.values.filter { $0 }.count
        let local = sidecarServerServices.filter { $0.group == "This Mac" || $0.status.lowercased().contains("local") }.count
        let favorites = sidecarServerServices.filter(\.favorite).count
        let loadProgress = min(1, sidecarMacSnapshot.loadAverage / 10)

        return [
            SidecarServerMetric(
                id: "reach",
                title: "Reachable",
                value: sidecarServerReachability.isEmpty ? "--" : "\(reachable)/\(sidecarServerReachability.count)",
                subtitle: sidecarServersChecking ? "checking now" : "service heartbeat",
                symbol: "antenna.radiowaves.left.and.right",
                color: Color(red: 0.32, green: 0.9, blue: 0.62),
                progress: Double(reachable) / Double(total)
            ),
            SidecarServerMetric(
                id: "mac",
                title: "This Mac",
                value: "\(sidecarMacSnapshot.runningApps) apps",
                subtitle: "\(local) local surfaces",
                symbol: "macbook",
                color: Color(red: 0.65, green: 0.82, blue: 1.0),
                progress: min(1, Double(sidecarMacSnapshot.runningApps) / 80)
            ),
            SidecarServerMetric(
                id: "load",
                title: "Load",
                value: String(format: "%.2f", sidecarMacSnapshot.loadAverage),
                subtitle: "1 min average",
                symbol: "speedometer",
                color: Color(red: 0.74, green: 0.52, blue: 1.0),
                progress: loadProgress
            ),
            SidecarServerMetric(
                id: "disk",
                title: "Disk Free",
                value: sidecarMacSnapshot.diskFreeLabel,
                subtitle: "\(favorites) pinned controls",
                symbol: "internaldrive",
                color: Color(red: 0.98, green: 0.72, blue: 0.25),
                progress: sidecarMacSnapshot.diskFreeFraction
            )
        ]
    }

    private var sidecarServerBars: [SidecarServerBar] {
        let groupCounts = Dictionary(grouping: sidecarServerServices) { service -> String in
            if service.group == "This Mac" || service.status.lowercased().contains("local") { return "Mac" }
            if service.group.contains("Admin") || service.name == "Proxmox" { return "Admin" }
            if service.status.lowercased().contains("cloud") || service.status.lowercased().contains("tailscale") { return "WAN" }
            if service.group == "Server" { return "Server" }
            return "Apps"
        }.mapValues(\.count)

        let maxCount = max(1, groupCounts.values.max() ?? 1)
        let specs: [(String, Color)] = [
            ("Mac", Color(red: 0.65, green: 0.82, blue: 1.0)),
            ("Server", Color(red: 0.32, green: 0.9, blue: 0.62)),
            ("Admin", Color(red: 0.98, green: 0.72, blue: 0.25)),
            ("WAN", Color(red: 0.74, green: 0.52, blue: 1.0)),
            ("Apps", Color(red: 1.0, green: 0.48, blue: 0.46))
        ]

        return specs.map { title, color in
            let count = groupCounts[title] ?? 0
            return SidecarServerBar(
                id: title,
                title: title,
                count: count,
                fraction: Double(count) / Double(maxCount),
                color: color
            )
        }
    }

    private var sidecarServerHeadline: String {
        guard !sidecarServerServices.isEmpty else { return "SERVICES.yaml" }
        if sidecarServersChecking { return "Checking services" }
        guard !sidecarServerReachability.isEmpty else { return "\(sidecarServerServices.count) services" }
        let up = sidecarServerReachability.values.filter { $0 }.count
        return "\(up)/\(sidecarServerReachability.count) reachable"
    }

    private var sidecarServerSubheadline: String {
        if let sidecarServersLastChecked {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last checked \(formatter.localizedString(for: sidecarServersLastChecked, relativeTo: Date()))"
        }
        return "Registry: \(NotchSwitchboardRegistry.defaultPath)"
    }

    private func sidecarServerDotColor(_ service: NotchSwitchboardService) -> Color {
        guard let reachable = sidecarServerReachability[service.id] else {
            return service.favorite ? Color(red: 0.98, green: 0.72, blue: 0.25) : .white.opacity(0.34)
        }
        return reachable ? Color(red: 0.32, green: 0.9, blue: 0.62) : Color(red: 1.0, green: 0.45, blue: 0.38)
    }

    private func sidecarServerStateLabel(_ service: NotchSwitchboardService) -> String {
        guard let reachable = sidecarServerReachability[service.id] else {
            return service.favorite ? "PIN" : "NEW"
        }
        return reachable ? "UP" : "DOWN"
    }

    private var selectedMacEntry: HermesSidecarFileEntry? {
        guard let selectedMacURL else { return nil }
        return macEntries.first { $0.url == selectedMacURL }
    }

    private var selectedMacEntries: [HermesSidecarFileEntry] {
        macEntries.filter { selectedMacURLs.contains($0.url) }
    }

    private var selectedMacItems: [URL] {
        selectedMacEntries.map(\.url)
    }

    private var selectedPreviewableMacURL: URL? {
        selectedMacEntries.first { !$0.isDirectory }?.url
    }

    private var macSelectionTitle: String {
        if selectedMacURLs.isEmpty {
            return "\(filteredMacEntries.count) item\(filteredMacEntries.count == 1 ? "" : "s")"
        }
        if selectedMacURLs.count == 1 {
            return selectedMacEntry?.name ?? "1 selected"
        }
        return "\(selectedMacURLs.count) selected"
    }

    private var macSelectionSubtitle: String {
        if selectedMacURLs.isEmpty {
            return macFooterSubtitle
        }
        if selectedMacURLs.count == 1 {
            return selectedMacEntry?.subtitle ?? "Selected item"
        }
        let folders = selectedMacEntries.filter(\.isDirectory).count
        let files = max(0, selectedMacURLs.count - folders)
        return "\(files) file\(files == 1 ? "" : "s"), \(folders) folder\(folders == 1 ? "" : "s")"
    }

    private var canShowMoreMacEntries: Bool {
        let trimmed = macSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredCount = trimmed.isEmpty ? macEntries.count : macEntries.filter { $0.name.lowercased().contains(trimmed) }.count
        return filteredMacEntries.count < filteredCount
    }

    private var macFooterSubtitle: String {
        if macIsLoading { return "Reading folder off the main UI thread" }
        if macTotalEntryCount > filteredMacEntries.count {
            return "Showing \(filteredMacEntries.count) of \(macTotalEntryCount). Select a file, then Space."
        }
        return "Select a file, then Space for Quick Look"
    }

    private var macBreadcrumbItems: [HermesSidecarBreadcrumbItem] {
        let standardized = macCurrentURL.standardizedFileURL
        let components = standardized.pathComponents.filter { $0 != "/" }
        var items: [HermesSidecarBreadcrumbItem] = [
            HermesSidecarBreadcrumbItem(title: "Mac", url: URL(fileURLWithPath: "/", isDirectory: true), isRoot: true, isLast: components.isEmpty)
        ]

        var path = ""
        for (index, component) in components.enumerated() {
            path += "/\(component)"
            items.append(
                HermesSidecarBreadcrumbItem(
                    title: component,
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isRoot: false,
                    isLast: index == components.count - 1
                )
            )
        }
        return items
    }

    private var macRootButtons: [HermesSidecarRootButton] {
        [
            HermesSidecarRootButton(title: "Home", symbol: "house.fill", url: DeskAgentLocalPaths.homeURL),
            HermesSidecarRootButton(title: "Projects", symbol: "folder.fill", url: DeskAgentLocalPaths.homeURL.appendingPathComponent("Projects", isDirectory: true)),
            HermesSidecarRootButton(title: "Apps", symbol: "square.grid.2x2.fill", url: URL(fileURLWithPath: DeskAgentLocalPaths.appsWorkspacePath, isDirectory: true)),
            HermesSidecarRootButton(title: "Notes", symbol: "doc.text.fill", url: URL(fileURLWithPath: DeskAgentLocalPaths.notesPath, isDirectory: true)),
            HermesSidecarRootButton(title: "Downloads", symbol: "arrow.down.circle.fill", url: DeskAgentLocalPaths.homeURL.appendingPathComponent("Downloads", isDirectory: true)),
            HermesSidecarRootButton(title: "Volumes", symbol: "internaldrive.fill", url: URL(fileURLWithPath: "/Volumes", isDirectory: true))
        ]
    }

    private var vaultRootButtons: [HermesSidecarRootButton] {
        [
            HermesSidecarRootButton(title: "Root", symbol: "books.vertical.fill", url: Self.obsidianVaultURL),
            HermesSidecarRootButton(title: "Inbox", symbol: "tray.full.fill", url: Self.obsidianVaultURL.appendingPathComponent("inbox")),
            HermesSidecarRootButton(title: "Projects", symbol: "folder.fill", url: Self.obsidianVaultURL.appendingPathComponent("projects")),
            HermesSidecarRootButton(title: "Research", symbol: "magnifyingglass", url: Self.obsidianVaultURL.appendingPathComponent("research"))
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private var filteredVaultEntries: [HermesSidecarFileEntry] {
        let trimmed = vaultSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noteEntries = vaultEntries.filter { $0.isDirectory || Self.obsidianPreviewExtensions.contains($0.url.pathExtension.lowercased()) }
        let filtered = trimmed.isEmpty ? noteEntries : noteEntries.filter { $0.name.lowercased().contains(trimmed) }
        return Array(filtered.prefix(vaultVisibleLimit))
    }

    private var canShowMoreVaultEntries: Bool {
        let trimmed = vaultSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noteEntries = vaultEntries.filter { $0.isDirectory || Self.obsidianPreviewExtensions.contains($0.url.pathExtension.lowercased()) }
        let filteredCount = trimmed.isEmpty ? noteEntries.count : noteEntries.filter { $0.name.lowercased().contains(trimmed) }.count
        return filteredVaultEntries.count < filteredCount
    }

    private var vaultPreviewAttributedText: AttributedString {
        let source = vaultNoteText.isEmpty ? "Select a note to preview it here." : vaultNoteText
        let markdown = Self.markdownByLinkingObsidianWikiLinks(source)
        return (try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }

    private func reloadMacEntries() {
        let url = macCurrentURL
        let loadID = UUID()
        macLoadID = loadID
        macIsLoading = true
        macError = nil
        macVisibleLimit = 80

        Task.detached(priority: .userInitiated) {
            let result = HermesSidecarFileEntry.loadDirectory(url)
            await MainActor.run {
                guard macLoadID == loadID else { return }
                switch result {
                case .success(let entries):
                    macEntries = entries
                    macTotalEntryCount = entries.count
                    selectedMacURLs = selectedMacURLs.filter { selectedURL in
                        entries.contains { $0.url == selectedURL }
                    }
                    if let selectedMacURL, !entries.contains(where: { $0.url == selectedMacURL }) {
                        self.selectedMacURL = nil
                    }
                    macError = nil
                case .failure(let error):
                    macEntries = []
                    macTotalEntryCount = 0
                    selectedMacURL = nil
                    selectedMacURLs.removeAll()
                    macError = error.localizedDescription
                }
                macIsLoading = false
            }
        }
    }

    private func reloadVaultEntries() {
        let url = vaultCurrentURL
        let loadID = UUID()
        vaultLoadID = loadID
        vaultIsLoading = true
        vaultError = nil
        vaultVisibleLimit = 80

        Task.detached(priority: .userInitiated) {
            let result = HermesSidecarFileEntry.loadDirectoryFast(url)
            await MainActor.run {
                guard vaultLoadID == loadID else { return }
                switch result {
                case .success(let entries):
                    vaultEntries = entries
                    if let selectedVaultURL, !entries.contains(where: { $0.url == selectedVaultURL }) {
                        self.selectedVaultURL = nil
                    }
                    vaultError = nil
                case .failure(let error):
                    vaultEntries = []
                    selectedVaultURL = nil
                    vaultError = error.localizedDescription
                }
                vaultIsLoading = false
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard vaultLoadID == loadID, vaultIsLoading else { return }
            vaultIsLoading = false
            vaultError = "Vault load timed out. Try refresh or open a smaller folder."
        }
    }

    private func loadSidecarServers() {
        let services = NotchSwitchboardRegistry.load()
        sidecarServerServices = services
        refreshSidecarDashboardSnapshot()
        if !services.isEmpty, sidecarServerReachability.isEmpty {
            refreshSidecarServers()
        }
    }

    private func refreshSidecarDashboardSnapshot() {
        sidecarMacSnapshot = SidecarMacSnapshot.current()
    }

    private func refreshSidecarServers() {
        if sidecarServerServices.isEmpty {
            loadSidecarServers()
        }
        let services = sidecarServerServices
        guard !services.isEmpty else { return }
        sidecarServersChecking = true
        refreshSidecarDashboardSnapshot()

        Task {
            let results = await NotchSwitchboardHealthChecker.check(services)
            await MainActor.run {
                sidecarServerReachability = results
                sidecarServersLastChecked = Date()
                sidecarServersChecking = false
                refreshSidecarDashboardSnapshot()
            }
        }
    }

    private func openSidecarServer(_ service: NotchSwitchboardService) {
        if let url = service.url {
            NSWorkspace.shared.open(url)
            return
        }
        if let folderPath = service.folderPath {
            openPath(folderPath)
        }
    }

    private func openParentMacFolder() {
        let parent = macCurrentURL.deletingLastPathComponent()
        guard parent.path != macCurrentURL.path else { return }
        navigateMacFolder(to: parent)
    }

    private func openMacFolder(_ url: URL) {
        navigateMacFolder(to: url)
    }

    private func navigateMacFolder(to url: URL, rememberHistory: Bool = true) {
        let standardized = url.standardizedFileURL
        guard standardized.path != macCurrentURL.standardizedFileURL.path else { return }
        if rememberHistory {
            macBackStack.append(macCurrentURL)
            macForwardStack.removeAll()
        }
        macCurrentURL = standardized
        selectedMacURL = nil
        selectedMacURLs.removeAll()
        macSearch = ""
        macVisibleLimit = 80
    }

    private func goBackMacFolder() {
        guard let previous = macBackStack.popLast() else { return }
        macForwardStack.append(macCurrentURL)
        navigateMacFolder(to: previous, rememberHistory: false)
    }

    private func goForwardMacFolder() {
        guard let next = macForwardStack.popLast() else { return }
        macBackStack.append(macCurrentURL)
        navigateMacFolder(to: next, rememberHistory: false)
    }

    private func revealCurrentMacFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([macCurrentURL])
    }

    private func openTerminalAtCurrentMacFolder() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", terminalURL.path, macCurrentURL.path]
        do {
            try process.run()
            state.statusMessage = "Opening Terminal in \(macCurrentURL.lastPathComponent.isEmpty ? macCurrentURL.path : macCurrentURL.lastPathComponent)."
        } catch {
            state.statusMessage = "Terminal failed: \(error.localizedDescription)"
        }
    }

    private func toggleMacSelection(_ url: URL) {
        if selectedMacURLs.contains(url) {
            selectedMacURLs.remove(url)
            if selectedMacURL == url {
                selectedMacURL = selectedMacURLs.first
            }
        } else {
            selectedMacURLs.insert(url)
            selectedMacURL = url
        }
    }

    private func openParentVaultFolder() {
        let parent = vaultCurrentURL.deletingLastPathComponent()
        guard parent.path.hasPrefix(Self.obsidianVaultURL.path), parent.path != vaultCurrentURL.path else { return }
        vaultCurrentURL = parent
        selectedVaultURL = nil
        vaultSearch = ""
    }

    private func previewSelectedMacFile() {
        guard let url = selectedPreviewableMacURL else { return }
        previewMacFile(url)
    }

    private func previewMacFile(_ url: URL) {
        let controller = SidecarQuickLookPreviewController(urls: [url])
        quickLookController = controller
        controller.show()
    }

    private func showSelectedMacItemInfo() {
        guard selectedMacURLs.count == 1, let url = selectedMacURLs.first else { return }
        showMacItemInfo(url)
    }

    private func showMacItemInfo(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedTypeDescriptionKey
        ])
        let isDirectory = values?.isDirectory == true
        let type = values?.localizedTypeDescription ?? (isDirectory ? "Folder" : "File")
        let size = isDirectory ? "Folder" : Self.formatMacByteCount(values?.totalFileSize ?? values?.fileSize)
        let modified = Self.formatMacInfoDate(values?.contentModificationDate)
        let created = Self.formatMacInfoDate(values?.creationDate)

        let alert = NSAlert()
        alert.messageText = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        alert.informativeText = """
        Kind: \(type)
        Size: \(size)
        Modified: \(modified)
        Created: \(created)
        Path: \(url.path)
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Path")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            copyMacPaths([url])
        }
    }

    private func openSelectedMacItem() {
        guard selectedMacURLs.count == 1, let selectedMacURL = selectedMacURLs.first else { return }
        NSWorkspace.shared.open(selectedMacURL)
    }

    private func revealSelectedMacItem() {
        let urls = selectedMacItems
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copySelectedMacPaths() {
        copyMacPaths(selectedMacItems)
    }

    private func copyMacPaths(_ urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        state.statusMessage = paths.count == 1 ? "Copied path." : "Copied \(paths.count) paths."
    }

    private func copyMacFilesToPasteboard(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(fileURLs.map { $0 as NSURL })
        state.statusMessage = "Copied \(fileURLs.count) file\(fileURLs.count == 1 ? "" : "s") to clipboard."
    }

    private func pasteMacFilesHere() {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else {
            state.statusMessage = "No copied files found on the clipboard."
            return
        }
        copyMacItems(urls, to: macCurrentURL, actionName: "Paste")
    }

    private func duplicateSelectedMacItems() {
        duplicateMacItems(selectedMacItems)
    }

    private func duplicateMacItems(_ urls: [URL]) {
        copyMacItems(urls, to: macCurrentURL, actionName: "Duplicate")
    }

    private func copyMacItems(_ urls: [URL], to destinationFolder: URL, actionName: String) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let result = Result { try MacFileOperationService.copyItems(urls, to: destinationFolder) }
            await MainActor.run {
                switch result {
                case .success(let copied):
                    selectedMacURLs = Set(copied)
                    selectedMacURL = copied.first
                    reloadMacEntries()
                    state.statusMessage = "\(actionName)d \(copied.count) item\(copied.count == 1 ? "" : "s")."
                case .failure(let error):
                    state.statusMessage = "\(actionName) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func moveSelectedMacItems() {
        moveMacItems(selectedMacItems)
    }

    private func moveMacItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let destinationFolder = chooseMacDestinationFolder() else { return }
        let itemLabel = "\(urls.count) item\(urls.count == 1 ? "" : "s")"
        guard confirmMacFileAction(
            title: "Move \(itemLabel)?",
            message: "Move selected item\(urls.count == 1 ? "" : "s") to \(destinationFolder.lastPathComponent.isEmpty ? destinationFolder.path : destinationFolder.lastPathComponent). Existing files will not be overwritten.",
            confirmTitle: "Move"
        ) else { return }

        Task.detached(priority: .userInitiated) {
            let result = Result { try MacFileOperationService.moveItems(urls, to: destinationFolder) }
            await MainActor.run {
                switch result {
                case .success(let moved):
                    selectedMacURLs = Set(moved)
                    selectedMacURL = moved.first
                    reloadMacEntries()
                    state.statusMessage = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s")."
                case .failure(let error):
                    state.statusMessage = "Move failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func trashSelectedMacItems() {
        trashMacItems(selectedMacItems)
    }

    private func trashMacItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let itemLabel = "\(urls.count) item\(urls.count == 1 ? "" : "s")"
        guard confirmMacFileAction(
            title: "Move \(itemLabel) to Trash?",
            message: "This uses macOS Trash, so it is recoverable from Finder. It is not a permanent delete.",
            confirmTitle: "Move to Trash",
            isDestructive: true
        ) else { return }

        Task.detached(priority: .userInitiated) {
            let result = Result { try MacFileOperationService.trashItems(urls) }
            await MainActor.run {
                switch result {
                case .success:
                    selectedMacURLs.removeAll()
                    selectedMacURL = nil
                    reloadMacEntries()
                    state.statusMessage = "Moved \(itemLabel) to Trash."
                case .failure(let error):
                    state.statusMessage = "Trash failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func attachSelectedMacItems() {
        attachMacItems(selectedMacItems)
    }

    private func attachMacItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            let attachment = NotchChatAttachment(url: url, kind: sidecarChatAttachmentKind(for: url))
            if !pendingAttachments.contains(where: { $0.url == attachment.url }) {
                pendingAttachments.append(attachment)
            }
        }
        activeSection = .chat
        state.statusMessage = "Attached \(urls.count) Mac item\(urls.count == 1 ? "" : "s") to Hermes."
    }

    private func sidecarChatAttachmentKind(for url: URL) -> NotchChatAttachmentKind {
        if url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return .localFolder
            }

            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
                return .localImage
            }
            if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) {
                return .localVideo
            }
            return .localFile
        }

        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            return .remoteImage
        }
        return .remoteFile
    }

    private func zipSelectedMacItems() {
        zipMacItems(selectedMacItems)
    }

    private func zipMacItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let result = Result { try MacFileOperationService.archive(urls) }
            await MainActor.run {
                switch result {
                case .success(let archive):
                    selectedMacURLs = [archive]
                    selectedMacURL = archive
                    reloadMacEntries()
                    state.statusMessage = "Created \(archive.lastPathComponent)."
                case .failure(let error):
                    state.statusMessage = "Zip failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createMacFolder() {
        guard let name = promptForMacItemName(title: "New Folder", message: "Create a folder in \(macCurrentURL.lastPathComponent.isEmpty ? macCurrentURL.path : macCurrentURL.lastPathComponent).", defaultValue: "New Folder") else { return }
        do {
            let url = try MacFileOperationService.createFolder(in: macCurrentURL, named: name)
            selectedMacURLs = [url]
            selectedMacURL = url
            reloadMacEntries()
            state.statusMessage = "Created \(url.lastPathComponent)."
        } catch {
            state.statusMessage = "New folder failed: \(error.localizedDescription)"
        }
    }

    private func createMacFile() {
        guard let name = promptForMacItemName(title: "New File", message: "Create a file in \(macCurrentURL.lastPathComponent.isEmpty ? macCurrentURL.path : macCurrentURL.lastPathComponent).", defaultValue: "Untitled.md") else { return }
        do {
            let url = try MacFileOperationService.createEmptyFile(in: macCurrentURL, named: name)
            selectedMacURLs = [url]
            selectedMacURL = url
            reloadMacEntries()
            state.statusMessage = "Created \(url.lastPathComponent)."
        } catch {
            state.statusMessage = "New file failed: \(error.localizedDescription)"
        }
    }

    private func renameSelectedMacItem() {
        guard selectedMacURLs.count == 1, let url = selectedMacURLs.first else { return }
        guard let name = promptForMacItemName(title: "Rename", message: "Rename \(url.lastPathComponent).", defaultValue: url.lastPathComponent) else { return }
        do {
            let renamed = try MacFileOperationService.rename(url, to: name)
            selectedMacURLs = [renamed]
            selectedMacURL = renamed
            reloadMacEntries()
            state.statusMessage = "Renamed to \(renamed.lastPathComponent)."
        } catch {
            state.statusMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func handleMacFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let sourceURL: URL?
                if let data = item as? Data {
                    sourceURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    sourceURL = url
                } else {
                    sourceURL = nil
                }
                guard let sourceURL else { return }
                Task { @MainActor in
                    copyDroppedMacItem(sourceURL)
                }
            }
        }
        return handled
    }

    private func copyDroppedMacItem(_ sourceURL: URL) {
        let destination = uniqueMacDropURL(for: sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            selectedMacURLs = [destination]
            selectedMacURL = destination
            reloadMacEntries()
            state.statusMessage = "Copied \(sourceURL.lastPathComponent) here."
        } catch {
            state.statusMessage = "Copy failed: \(error.localizedDescription)"
        }
    }

    private func uniqueMacDropURL(for filename: String) -> URL {
        let basename = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        var candidate = macCurrentURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        for index in 2...999 {
            candidate = macCurrentURL.appendingPathComponent("\(basename) \(index)")
            if !ext.isEmpty {
                candidate = candidate.appendingPathExtension(ext)
            }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return macCurrentURL.appendingPathComponent("\(basename) \(UUID().uuidString)").appendingPathExtension(ext)
    }

    private func promptForMacItemName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func chooseMacDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Folder"
        panel.message = "Move selected Sidecar Mac items to this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = macCurrentURL

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func confirmMacFileAction(title: String, message: String, confirmTitle: String, isDestructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isDestructive ? .warning : .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func loadVaultNote(_ url: URL) {
        vaultNoteTitle = url.deletingPathExtension().lastPathComponent
        vaultNoteText = ""
        vaultNoteError = nil
        vaultResolvingLink = ""
        vaultNoteIsLoading = true
        let loadID = UUID()
        vaultNoteLoadID = loadID

        Task.detached(priority: .userInitiated) {
            let result = HermesSidecarFileEntry.readTextPreview(url, maxBytes: 260_000)
            await MainActor.run {
                guard vaultNoteLoadID == loadID else { return }
                switch result {
                case .success(let text):
                    vaultNoteText = text
                    vaultNoteError = nil
                case .failure(let error):
                    vaultNoteText = ""
                    vaultNoteError = error.localizedDescription
                }
                vaultNoteIsLoading = false
            }
        }
    }

    private func openSelectedVaultNoteInObsidian() {
        guard let selectedVaultURL else {
            NSWorkspace.shared.open(Self.obsidianVaultURL)
            return
        }
        NSWorkspace.shared.open(obsidianOpenURL(for: selectedVaultURL))
    }

    private func revealSelectedVaultNote() {
        guard let selectedVaultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedVaultURL])
    }

    private func handleVaultPreviewLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == Self.sidecarVaultLinkScheme {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let target = components?.queryItems?.first(where: { $0.name == "target" })?.value ?? ""
            openVaultWikiTarget(target)
            return .handled
        }
        return .systemAction
    }

    private func openVaultWikiTarget(_ target: String) {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { return }
        vaultResolvingLink = "Opening [[\(cleanTarget)]]..."

        let currentFolder = selectedVaultURL?.deletingLastPathComponent() ?? vaultCurrentURL
        let vaultRoot = Self.obsidianVaultURL
        Task.detached(priority: .userInitiated) {
            let match = HermesSidecarFileEntry.resolveObsidianWikiTarget(cleanTarget, vaultRoot: vaultRoot, currentFolder: currentFolder)
            await MainActor.run {
                guard let match else {
                    vaultResolvingLink = "Could not find [[\(cleanTarget)]]."
                    return
                }
                vaultResolvingLink = ""
                vaultCurrentURL = match.deletingLastPathComponent()
                selectedVaultURL = match
                vaultSearch = ""
                loadVaultNote(match)
            }
        }
    }

    private func vaultRelativePath(_ url: URL) -> String {
        let vaultPath = Self.obsidianVaultURL.path
        guard url.path.hasPrefix(vaultPath) else { return url.path }
        let relative = String(url.path.dropFirst(vaultPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/" : relative
    }

    private func obsidianOpenURL(for url: URL) -> URL {
        let relative = vaultRelativePath(url)
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: "1note"),
            URLQueryItem(name: "file", value: relative)
        ]
        return components.url ?? url
    }

    private static func markdownByLinkingObsidianWikiLinks(_ text: String) -> String {
        let pattern = #"\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        var output = text

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let raw = nsText.substring(with: match.range(at: 1))
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
            let label = (parts.count > 1 ? parts[1] : target).trimmingCharacters(in: .whitespacesAndNewlines)
            let escapedLabel = label
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            var components = URLComponents()
            components.scheme = sidecarVaultLinkScheme
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "target", value: target)]
            let url = components.url?.absoluteString ?? ""
            output = (output as NSString).replacingCharacters(in: match.range, with: "[\(escapedLabel)](\(url))")
        }

        return output
    }

    private var macRows: [HermesSidecarActionRow] {
        [
            HermesSidecarActionRow(title: "Home", subtitle: "~", symbol: "house.fill", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                openPath(DeskAgentLocalPaths.homePath)
            },
            HermesSidecarActionRow(title: "Projects", subtitle: "Keeper repos and active Mac apps", symbol: "folder.fill", accent: Color(red: 1.0, green: 0.72, blue: 0.28)) {
                openPath("\(DeskAgentLocalPaths.homePath)/Projects")
            },
            HermesSidecarActionRow(title: "Apps Workspace", subtitle: "Local prototypes and helpers", symbol: "square.grid.2x2.fill", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openPath(DeskAgentLocalPaths.appsWorkspacePath)
            },
            HermesSidecarActionRow(title: "MarkShot Suite", subtitle: "Desk Agent Notch source", symbol: "terminal.fill", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                openPath(DeskAgentLocalPaths.sourcePath)
            },
            HermesSidecarActionRow(title: "Notes", subtitle: "Local notes and setup docs", symbol: "doc.text.fill", accent: Color(red: 0.6, green: 0.82, blue: 1.0)) {
                openPath(DeskAgentLocalPaths.notesPath)
            },
            HermesSidecarActionRow(title: "Downloads", subtitle: "Recent incoming files", symbol: "arrow.down.circle.fill", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                openPath("\(DeskAgentLocalPaths.homePath)/Downloads")
            }
        ]
    }

    private var serverRows: [HermesSidecarActionRow] {
        [
            HermesSidecarActionRow(title: "AIOS", subtitle: "Hermes cockpit on this Mac", symbol: "cpu.fill", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                openURLString("http://127.0.0.1:3217")
            },
            HermesSidecarActionRow(title: "Hermes Dashboard", subtitle: "Local Hermes control page", symbol: "brain.head.profile", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openURLString("http://127.0.0.1:9119")
            },
            HermesSidecarActionRow(title: "Plex", subtitle: "Server music and media", symbol: "play.tv.fill", accent: Color(red: 0.98, green: 0.68, blue: 0.08)) {
                openURLString("https://app.plex.tv")
            },
            HermesSidecarActionRow(title: "n8n", subtitle: "Automation workflows", symbol: "point.3.connected.trianglepath.dotted", accent: Color(red: 1.0, green: 0.5, blue: 0.36)) {
                openURLString(DeskAgentLocalPaths.n8nURL)
            },
            HermesSidecarActionRow(title: "Glance", subtitle: "Server dashboard", symbol: "rectangle.grid.2x2.fill", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                openURLString(DeskAgentLocalPaths.glanceURL)
            },
            HermesSidecarActionRow(title: "Tailscale Admin", subtitle: "Remote network control plane", symbol: "network", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                openURLString("https://login.tailscale.com/admin/machines")
            }
        ]
    }

    private var filteredActionRows: [HermesSidecarActionRow] {
        let trimmed = sidecarActionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return actionRows }
        return actionRows.filter { row in
            row.title.lowercased().contains(trimmed) || row.subtitle.lowercased().contains(trimmed)
        }
    }

    private var actionRows: [HermesSidecarActionRow] {
        [
            HermesSidecarActionRow(title: "Chat with Hermes", subtitle: "Jump back to the shared agent thread", symbol: "bubble.left.and.text.bubble.right.fill", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeSection = .chat
                }
            },
            HermesSidecarActionRow(title: "Search Vault", subtitle: "Open Obsidian notes inside the sidecar", symbol: "books.vertical.fill", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeSection = .vault
                }
            },
            HermesSidecarActionRow(title: "Find Mac Files", subtitle: "Browse folders and Quick Look files", symbol: "macwindow", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeSection = .mac
                }
            },
            HermesSidecarActionRow(title: "Search Services", subtitle: "Open the server dashboard and Switchboard drawer", symbol: "server.rack", accent: Color(red: 1.0, green: 0.72, blue: 0.28)) {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeSection = .servers
                }
            },
            HermesSidecarActionRow(
                title: sidecarRoomRestore == nil ? "Make Room" : "Restore Room",
                subtitle: sidecarRoomRestore == nil ? "Push the front browser/app left of the sidecar" : "Put \(sidecarRoomRestore?.ownerName ?? "the app") back where it was",
                symbol: sidecarRoomRestore == nil ? "rectangle.split.2x1.fill" : "arrow.uturn.backward",
                accent: Color(red: 0.6, green: 0.82, blue: 1.0)
            ) {
                toggleRoomForSidecar()
            },
            HermesSidecarActionRow(title: "AIOS", subtitle: "Open the local AI OS cockpit", symbol: "cpu.fill", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                openURLString("http://127.0.0.1:3217")
            },
            HermesSidecarActionRow(title: "Hermes Dashboard", subtitle: "Open the local Hermes control page", symbol: "brain.head.profile", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openURLString("http://127.0.0.1:9119")
            },
            HermesSidecarActionRow(title: "Apple Shortcuts", subtitle: "Native automations and Desk Agent App Intents", symbol: "square.stack.3d.up.fill", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                openPath("/System/Applications/Shortcuts.app")
            },
            HermesSidecarActionRow(title: "n8n Automations", subtitle: "Workflow automations", symbol: "point.3.connected.trianglepath.dotted", accent: Color(red: 1.0, green: 0.5, blue: 0.36)) {
                openURLString(DeskAgentLocalPaths.n8nURL)
            },
            HermesSidecarActionRow(title: "Prompt Library", subtitle: "Open reusable prompts in Obsidian", symbol: "text.book.closed.fill", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                openFirstExistingPath([
                    DeskAgentLocalPaths.obsidianVaultURL.appendingPathComponent("research/prompt-library").path,
                    DeskAgentLocalPaths.obsidianVaultURL.appendingPathComponent("research").path
                ])
            },
            HermesSidecarActionRow(title: "System Controls", subtitle: "Open OS settings and utility launchers", symbol: "gearshape.2.fill", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeSection = .system
                }
            },
            HermesSidecarActionRow(title: "Activity Monitor", subtitle: "Check CPU, memory, network, and stuck apps", symbol: "waveform.path.ecg", accent: Color(red: 1.0, green: 0.45, blue: 0.38)) {
                openPath("/System/Applications/Utilities/Activity Monitor.app")
            },
            HermesSidecarActionRow(title: "Terminal", subtitle: "Open a local shell", symbol: "terminal.fill", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openPath("/System/Applications/Utilities/Terminal.app")
            }
        ]
    }

    private var systemRows: [HermesSidecarActionRow] {
        [
            HermesSidecarActionRow(title: "System Settings", subtitle: "Main Mac settings app", symbol: "gearshape.fill", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                openPath("/System/Applications/System Settings.app")
            },
            HermesSidecarActionRow(
                title: sidecarRoomRestore == nil ? "Make Room" : "Restore Room",
                subtitle: sidecarRoomRestore == nil ? "Resize the front app beside the sidecar" : "Restore \(sidecarRoomRestore?.ownerName ?? "the app") window size",
                symbol: sidecarRoomRestore == nil ? "rectangle.split.2x1.fill" : "arrow.uturn.backward",
                accent: Color(red: 0.6, green: 0.82, blue: 1.0)
            ) {
                toggleRoomForSidecar()
            },
            HermesSidecarActionRow(title: "Privacy & Security", subtitle: "Permissions, screen recording, microphone", symbol: "lock.shield.fill", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security")
            },
            HermesSidecarActionRow(title: "Accessibility", subtitle: "Control Mac permissions for agents", symbol: "figure.stand", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            },
            HermesSidecarActionRow(title: "Screen Recording", subtitle: "Screen visibility permissions", symbol: "rectangle.on.rectangle", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            },
            HermesSidecarActionRow(title: "Sound", subtitle: "Input/output devices and volume", symbol: "speaker.wave.2.fill", accent: Color(red: 1.0, green: 0.72, blue: 0.28)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.sound")
            },
            HermesSidecarActionRow(title: "Displays", subtitle: "Arrangement, resolution, brightness", symbol: "display", accent: Color(red: 0.6, green: 0.82, blue: 1.0)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.displays")
            },
            HermesSidecarActionRow(title: "Network", subtitle: "Wi-Fi, Ethernet, VPN, Tailscale checks", symbol: "network", accent: Color(red: 0.32, green: 0.9, blue: 0.62)) {
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.network")
            },
            HermesSidecarActionRow(title: "Activity Monitor", subtitle: "CPU, memory, network, stuck apps", symbol: "waveform.path.ecg", accent: Color(red: 1.0, green: 0.45, blue: 0.38)) {
                openPath("/System/Applications/Utilities/Activity Monitor.app")
            },
            HermesSidecarActionRow(title: "Terminal", subtitle: "Open a local shell", symbol: "terminal.fill", accent: Color(red: 0.75, green: 0.48, blue: 1.0)) {
                openPath("/System/Applications/Utilities/Terminal.app")
            },
            HermesSidecarActionRow(title: "Disk Utility", subtitle: "Drives, mounts, storage health", symbol: "internaldrive.fill", accent: Color(red: 0.98, green: 0.72, blue: 0.25)) {
                openPath("/System/Applications/Utilities/Disk Utility.app")
            },
            HermesSidecarActionRow(title: "Shortcuts", subtitle: "Apple automation and App Intents", symbol: "square.stack.3d.up.fill", accent: Color(red: 0.34, green: 0.68, blue: 1.0)) {
                openPath("/System/Applications/Shortcuts.app")
            },
            HermesSidecarActionRow(title: "Lock Display", subtitle: "Put the screen to sleep", symbol: "lock.fill", accent: Color(red: 0.9, green: 0.9, blue: 0.92)) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                try? process.run()
            }
        ]
    }

    private func toggleRoomForSidecar() {
        if sidecarRoomRestore == nil {
            makeRoomForSidecar()
        } else {
            restoreRoomForSidecar()
        }
    }

    private func makeRoomForSidecar() {
        guard let target = topNonDeskAgentWindow() else {
            state.statusMessage = "No window found to move beside the sidecar."
            return
        }

        let sidecarWidth: CGFloat = 454
        let gap: CGFloat = 10
        let screen = NSScreen.screens.first { screen in
            let frame = screen.frame
            return target.bounds.midX >= frame.minX
                && target.bounds.midX <= frame.maxX
                && (frame.maxY - target.bounds.midY) >= frame.minY
                && (frame.maxY - target.bounds.midY) <= frame.maxY
        } ?? NSScreen.main

        guard let screen else {
            state.statusMessage = "Could not find the screen for that window."
            return
        }

        let visible = screen.visibleFrame
        let width = max(640, visible.width - sidecarWidth - gap)
        let height = max(420, visible.height)
        let x = max(visible.minX, screen.frame.minX)
        let y = max(0, screen.frame.maxY - visible.maxY)
        let restore = SidecarRoomRestore(
            processIdentifier: target.processIdentifier,
            ownerName: target.ownerName,
            x: Int(target.bounds.minX),
            y: Int(target.bounds.minY),
            width: Int(target.bounds.width),
            height: Int(target.bounds.height)
        )
        let script = """
        tell application "System Events"
            set targetProcesses to application processes whose unix id is \(target.processIdentifier)
            if (count of targetProcesses) is 0 then error "Target process not found"
            tell item 1 of targetProcesses
                if (count of windows) is 0 then error "No windows"
                set bestWindow to missing value
                set bestArea to 0
                repeat with candidateWindow in windows
                    try
                        set candidateSize to size of candidateWindow
                        set candidateArea to (item 1 of candidateSize) * (item 2 of candidateSize)
                        if candidateArea is greater than bestArea then
                            set bestArea to candidateArea
                            set bestWindow to candidateWindow
                        end if
                    end try
                end repeat
                if bestWindow is missing value then error "No movable windows"
                set position of bestWindow to {\(Int(x)), \(Int(y))}
                set size of bestWindow to {\(Int(width)), \(Int(height))}
            end tell
        end tell
        """

        runSidecarAppleScript(script) { succeeded in
            if succeeded {
                sidecarRoomRestore = restore
                state.statusMessage = "Made room for \(target.ownerName)."
            } else {
                state.statusMessage = "Allow MarkShot in Accessibility to move app windows."
                openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    private func restoreRoomForSidecar() {
        guard let restore = sidecarRoomRestore else {
            state.statusMessage = "No saved window layout to restore."
            return
        }

        let script = """
        tell application "System Events"
            set targetProcesses to application processes whose unix id is \(restore.processIdentifier)
            if (count of targetProcesses) is 0 then error "Target process not found"
            tell item 1 of targetProcesses
                if (count of windows) is 0 then error "No windows"
                set bestWindow to missing value
                set bestArea to 0
                repeat with candidateWindow in windows
                    try
                        set candidateSize to size of candidateWindow
                        set candidateArea to (item 1 of candidateSize) * (item 2 of candidateSize)
                        if candidateArea is greater than bestArea then
                            set bestArea to candidateArea
                            set bestWindow to candidateWindow
                        end if
                    end try
                end repeat
                if bestWindow is missing value then error "No movable windows"
                set position of bestWindow to {\(restore.x), \(restore.y)}
                set size of bestWindow to {\(restore.width), \(restore.height)}
            end tell
        end tell
        """

        runSidecarAppleScript(script) { succeeded in
            if succeeded {
                sidecarRoomRestore = nil
                state.statusMessage = "Restored \(restore.ownerName)."
            } else {
                state.statusMessage = "Could not restore \(restore.ownerName)."
            }
        }
    }

    private func topNonDeskAgentWindow() -> (processIdentifier: pid_t, ownerName: String, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ignoredOwners: Set<String> = ["MarkShot", "Desk Agent", "Window Server", "Dock", "SystemUIServer"]

        return windowInfo.compactMap { info -> (processIdentifier: pid_t, ownerName: String, bounds: CGRect)? in
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ignoredOwners.contains(ownerName),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 520,
                  bounds.height > 320,
                  bounds.width * bounds.height > 240_000 else {
                return nil
            }

            return (pidNumber.int32Value, ownerName, bounds)
        }
        .max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private func runSidecarAppleScript(_ script: String, completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0)
            }
        }
        do {
            try process.run()
        } catch {
            completion(false)
        }
    }

    private func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openFirstExistingPath(_ paths: [String]) {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        openPath(path)
    }

    private func openURLString(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSystemSettingsPane(_ string: String) {
        guard let url = URL(string: string) else {
            openPath("/System/Applications/System Settings.app")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func diskSummary(for url: URL) -> String {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            guard let available = values.volumeAvailableCapacityForImportantUsage,
                  let total = values.volumeTotalCapacity else {
                return "Storage unavailable"
            }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useTB]
            formatter.countStyle = .file
            let availableText = formatter.string(fromByteCount: available)
            let totalText = formatter.string(fromByteCount: Int64(total))
            return "\(availableText) free of \(totalText)"
        } catch {
            return "Storage unavailable"
        }
    }

    private static func formatMacByteCount(_ bytes: Int?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func formatMacInfoDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static let obsidianVaultURL = DeskAgentLocalPaths.obsidianVaultURL
    private static let obsidianPreviewExtensions: Set<String> = ["md", "markdown", "txt", "canvas"]
    private static let sidecarVaultLinkScheme = "deskagent-vault"
}

private struct HermesSidecarActionRow: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    let action: () -> Void
}

private struct HermesSidecarRootButton: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let url: URL
}

private struct HermesSidecarBreadcrumbItem: Identifiable {
    var id: String { url.path }
    let title: String
    let url: URL
    let isRoot: Bool
    let isLast: Bool
}

private struct HermesSidecarFileEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedAt: Date?

    init?(url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            self.url = url
            self.id = url.path
            self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            self.isDirectory = values.isDirectory ?? false
            self.fileSize = values.fileSize.map(Int64.init)
            self.modifiedAt = values.contentModificationDate
        } catch {
            return nil
        }
    }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.id = url.path
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isDirectory = isDirectory
        self.fileSize = nil
        self.modifiedAt = nil
    }

    static func loadDirectory(_ url: URL) -> Result<[HermesSidecarFileEntry], Error> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(HermesSidecarFileBrowserError.notReachable)
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let entries = urls.compactMap(HermesSidecarFileEntry.init(url:))
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return .success(entries)
        } catch {
            return .failure(error)
        }
    }

    static func loadDirectoryFast(_ url: URL) -> Result<[HermesSidecarFileEntry], Error> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(HermesSidecarFileBrowserError.notReachable)
        }

        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let entries = names
                .filter { !$0.hasPrefix(".") }
                .map { name -> HermesSidecarFileEntry in
                    let child = url.appendingPathComponent(name)
                    var childIsDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory)
                    return HermesSidecarFileEntry(url: child, isDirectory: childIsDirectory.boolValue)
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return .success(entries)
        } catch {
            return .failure(error)
        }
    }

    static func readTextPreview(_ url: URL, maxBytes: Int) -> Result<String, Error> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            let data = handle.readData(ofLength: maxBytes + 1)
            let clipped = data.count > maxBytes
            let body = data.prefix(maxBytes)
            guard var text = String(data: body, encoding: .utf8) else {
                return .failure(HermesSidecarFileBrowserError.notText)
            }
            if clipped {
                text += "\n\n[Preview truncated]"
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    static func resolveObsidianWikiTarget(_ target: String, vaultRoot: URL, currentFolder: URL) -> URL? {
        let normalizedTarget = target
            .split(separator: "#", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? target
        guard !normalizedTarget.isEmpty else { return nil }

        let targetWithExtension = normalizedTarget.hasSuffix(".md") ? normalizedTarget : "\(normalizedTarget).md"
        let directCandidates = [
            currentFolder.appendingPathComponent(targetWithExtension),
            vaultRoot.appendingPathComponent(targetWithExtension)
        ]

        if let direct = directCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return direct
        }

        let targetFilename = URL(fileURLWithPath: targetWithExtension).lastPathComponent.lowercased()
        let targetStem = URL(fileURLWithPath: targetWithExtension).deletingPathExtension().lastPathComponent.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let filename = url.lastPathComponent.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if filename == targetFilename || stem == targetStem || url.path.lowercased().hasSuffix(targetWithExtension.lowercased()) {
                return url
            }
        }

        return nil
    }

    var subtitle: String {
        if isDirectory { return "Folder" }
        let sizeText = fileSize.map(Self.formatBytes(_:)) ?? "File"
        if let modifiedAt {
            return "\(sizeText) • \(Self.relativeDateFormatter.localizedString(for: modifiedAt, relativeTo: Date()))"
        }
        return sizeText
    }

    var displayNameWithoutExtension: String {
        isDirectory ? name : url.deletingPathExtension().lastPathComponent
    }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "photo.fill"
        case "mov", "mp4", "m4v": return "film.fill"
        case "mp3", "m4a", "wav", "aiff", "flac": return "music.note"
        case "md", "txt", "rtf": return "doc.text.fill"
        case "pdf": return "doc.richtext.fill"
        case "swift", "js", "ts", "tsx", "json", "yaml", "yml", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private enum HermesSidecarFileBrowserError: LocalizedError {
    case notReachable
    case notText

    var errorDescription: String? {
        switch self {
        case .notReachable:
            return "Folder is not reachable."
        case .notText:
            return "This file is not readable as text."
        }
    }
}

private final class SidecarQuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    func show() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

private struct HermesChatPopoutView: View {
    @Binding var messages: [NotchChatMessage]
    @Binding var draft: String
    @Binding var pendingAttachments: [NotchChatAttachment]

    let isSending: Bool
    let thinkingLabel: String
    let onSend: () -> Void
    let onAttachLatest: () -> Void
    let onAttachCapture: () -> Void
    let onAttachClipboard: () -> Void
    let onAddMacContext: () -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool
    let onNewChat: () -> Void
    let onOpenSkills: () -> Void
    let onDockLeft: () -> Void
    let onDockRight: () -> Void

    @State private var activePulse = false
    @State private var terminalVisible = false
    @State private var terminalExpanded = false
    @State private var terminalCommand = ""
    @State private var terminalOutput = "Embedded terminal ready. Commands run with zsh in your home folder."
    @State private var terminalIsRunning = false
    @State private var compactMode = false

    var body: some View {
        Group {
            if compactMode {
                compactViewer
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Color.white.opacity(0.08))
                    messageList
                    if terminalVisible {
                        embeddedTerminal
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                .frame(minWidth: 420, minHeight: 460)
                .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .background(
            ZStack {
                Color.black
                
                // Subtle top-left radial glow matching the mint accent.
                RadialGradient(
                    colors: [Color(red: 0.12, green: 0.3, blue: 0.25).opacity(0.12), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 400
                )
                
                // Subtle bottom-right deep blue/cyan glow
                RadialGradient(
                    colors: [Color(red: 0.05, green: 0.1, blue: 0.15).opacity(0.08), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 300
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: compactMode ? 20 : 0, style: .continuous))
        .onDrop(of: NotchShelfView.chatDropTypes, isTargeted: nil) { providers in
            onDropProviders(providers)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: compactMode)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                activePulse = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Same thread as the notch")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer(minLength: 0)

            PopoutCircleButton(
                symbol: "sidebar.left",
                helpText: "Dock chat left",
                isPrimary: false,
                isDisabled: false,
                action: onDockLeft
            )

            PopoutCircleButton(
                symbol: "sidebar.right",
                helpText: "Dock chat right",
                isPrimary: false,
                isDisabled: false,
                action: onDockRight
            )

            PopoutCircleButton(
                symbol: "rectangle.compress.vertical",
                helpText: "Compact floating viewer",
                isPrimary: false,
                isDisabled: false,
                action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        compactMode = true
                        terminalVisible = false
                    }
                }
            )

            PopoutCircleButton(
                symbol: "terminal",
                helpText: terminalVisible ? "Hide embedded terminal" : "Show embedded terminal",
                isPrimary: false,
                isDisabled: false,
                action: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        terminalVisible.toggle()
                    }
                }
            )

            PopoutCircleButton(
                symbol: "list.bullet.clipboard",
                helpText: "Open skills reference",
                isPrimary: false,
                isDisabled: false,
                action: onOpenSkills
            )

            PopoutCircleButton(
                symbol: "plus",
                helpText: "New chat",
                isPrimary: false,
                isDisabled: false,
                action: onNewChat
            )
        }
        .padding(.top, 28) // Pushed down to clear macOS traffic lights
        .padding(.leading, 70) // Shipped right to sit alongside macOS traffic lights
        .padding(.trailing, 18)
        .padding(.bottom, 14)
    }

    private var compactViewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: latestCompactMessage?.role == .user ? "person.crop.circle" : "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.62))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.07), in: Circle())

                VStack(alignment: .leading, spacing: 0) {
                    Text("Hermes")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(compactSubtitle)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.36))
                }

                Spacer(minLength: 0)

                PopoutCircleButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    helpText: "Restore chat",
                    isPrimary: false,
                    isDisabled: false,
                    action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            compactMode = false
                        }
                    }
                )
            }

            Text(compactPreviewText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(width: 280, height: 128, alignment: .topLeading)
    }

    private var latestCompactMessage: NotchChatMessage? {
        messages.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var compactSubtitle: String {
        if isSending { return "thinking" }
        guard let message = latestCompactMessage else { return "ready" }
        switch message.role {
        case .user: return "you"
        case .assistant: return "reply"
        case .system: return "status"
        }
    }

    private var compactPreviewText: String {
        if isSending {
            return thinkingLabel
        }
        return latestCompactMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Hermes ready."
    }

    private var embeddedTerminal: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.32, green: 0.9, blue: 0.62))
                Text("Terminal")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Text("~/")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
                Spacer(minLength: 0)
                PopoutCircleButton(
                    symbol: "text.bubble",
                    helpText: "Ask Hermes about terminal output",
                    isPrimary: false,
                    isDisabled: terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terminalIsRunning,
                    action: attachTerminalOutputToDraft
                )
                PopoutCircleButton(
                    symbol: "doc.on.doc",
                    helpText: "Copy terminal output",
                    isPrimary: false,
                    isDisabled: terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: copyTerminalOutput
                )
                PopoutCircleButton(
                    symbol: terminalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    helpText: terminalExpanded ? "Shrink terminal" : "Expand terminal",
                    isPrimary: false,
                    isDisabled: false,
                    action: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            terminalExpanded.toggle()
                        }
                    }
                )
                PopoutCircleButton(
                    symbol: "xmark",
                    helpText: "Hide terminal",
                    isPrimary: false,
                    isDisabled: false,
                    action: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            terminalVisible = false
                        }
                    }
                )
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(terminalOutput)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(height: terminalExpanded ? 210 : 104)
            .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))

            HStack(spacing: 8) {
                TextField("zsh command...", text: $terminalCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.055), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                    .disabled(terminalIsRunning)
                    .onSubmit(runTerminalCommand)

                PopoutCircleButton(
                    symbol: terminalIsRunning ? "hourglass" : "play.fill",
                    helpText: terminalIsRunning ? "Command running" : "Run command",
                    isPrimary: !terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isDisabled: terminalIsRunning || terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: runTerminalCommand
                )
                PopoutCircleButton(
                    symbol: "trash",
                    helpText: "Clear terminal output",
                    isPrimary: false,
                    isDisabled: terminalIsRunning,
                    action: clearTerminalOutput
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color.black.opacity(0.92)
                .overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .top)
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(messages) { message in
                        popoutBubble(message)
                            .id(message.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(thinkingLabel)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(activePulse ? 0.72 : 0.32))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color.white.opacity(activePulse ? 0.055 : 0.025),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color(red: 0.34, green: 0.68, blue: 1.0).opacity(activePulse ? 0.42 : 0.12),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: Color(red: 0.34, green: 0.68, blue: 1.0).opacity(activePulse ? 0.25 : 0.0),
                            radius: activePulse ? 6 : 0
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _ in
                scrollToLatestPopoutMessage(proxy, animated: true)
            }
            .onChange(of: isSending) { _ in
                DispatchQueue.main.async {
                    scrollToLatestPopoutMessage(proxy, animated: true)
                }
            }
            .onAppear {
                scrollToLatestPopoutMessage(proxy, animated: false)
                DispatchQueue.main.async {
                    scrollToLatestPopoutMessage(proxy, animated: false)
                }
            }
        }
    }

    private func scrollToLatestPopoutMessage(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func runTerminalCommand() {
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !terminalIsRunning else { return }

        terminalIsRunning = true
        terminalOutput = "$ \(command)\nRunning..."

        Task.detached {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = DeskAgentLocalPaths.homeURL
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                let result = combined.isEmpty ? "(no output)" : combined
                let clipped = String(result.prefix(12000))
                let suffix = result.count > clipped.count ? "\n\n...output truncated..." : ""
                await MainActor.run {
                    terminalOutput = "$ \(command)\n\(clipped)\(suffix)\n\nexit \(process.terminationStatus)"
                    terminalCommand = ""
                    terminalIsRunning = false
                }
            } catch {
                await MainActor.run {
                    terminalOutput = "$ \(command)\nFailed: \(error.localizedDescription)"
                    terminalIsRunning = false
                }
            }
        }
    }

    private func attachTerminalOutputToDraft() {
        let output = terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }

        let clipped = String(output.prefix(6000))
        let suffix = output.count > clipped.count ? "\n\n[output clipped]" : ""
        let prompt = """
        Explain this terminal output and tell me the next best step:

        ```text
        \(clipped)\(suffix)
        ```
        """

        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = prompt
        } else {
            draft += "\n\n" + prompt
        }
    }

    private func copyTerminalOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(terminalOutput, forType: .string)
    }

    private func clearTerminalOutput() {
        terminalOutput = "Embedded terminal ready. Commands run with zsh in your home folder."
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            popoutPendingAttachmentPill(attachment)
                        }
                    }
                }
                .frame(height: 26)
            }

            HStack(spacing: 10) {
                PopoutCircleButton(
                    symbol: pendingAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill",
                    helpText: pendingAttachments.isEmpty ? "Attach files or folders" : "\(pendingAttachments.count) attached",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachLatest
                )
                PopoutCircleButton(
                    symbol: "photo.on.rectangle",
                    helpText: "Attach latest capture",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachCapture
                )
                PopoutCircleButton(
                    symbol: "doc.on.clipboard",
                    helpText: "Add clipboard to chat",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAttachClipboard
                )
                PopoutCircleButton(
                    symbol: "macwindow",
                    helpText: "Add current Mac app context",
                    isPrimary: false,
                    isDisabled: false,
                    action: onAddMacContext
                )

                PopoutComposerField(text: $draft, isSending: isSending, onSubmit: onSend)

                let isDraftEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty
                PopoutCircleButton(
                    symbol: "arrow.up",
                    helpText: isDraftEmpty ? "Type or attach something" : "Send message",
                    isPrimary: !isDraftEmpty,
                    isDisabled: isDraftEmpty || isSending,
                    action: onSend
                )
            }
        }
        .padding(16)
        .background(
            Color.black.opacity(0.88)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private func popoutPendingAttachmentPill(_ attachment: NotchChatAttachment) -> some View {
        HStack(spacing: 7) {
            Image(systemName: attachment.symbol)
            Text(attachment.title).lineLimit(1)
            Button {
                pendingAttachments.removeAll { $0.id == attachment.id || $0.url == attachment.url }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.58))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color.white.opacity(0.045), in: Capsule())
    }

    private func popoutBubble(_ message: NotchChatMessage) -> some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 70)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(message.role == .user ? Color.black.opacity(0.84) : .white.opacity(0.78))
                        .textSelection(.enabled)
                }

                if let source = message.source, !source.isEmpty {
                    let isPhone = (source == "iphone" || source == "phone")
                    let isLive = (source == "live" || source == "voice")
                    HStack(spacing: 3) {
                        Image(systemName: isPhone ? "iphone" : (isLive ? "waveform.circle.fill" : "waveform"))
                            .font(.system(size: 9, weight: .bold))
                        Text(source == "iphone" ? "phone" : source)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(
                        message.role == .user 
                            ? (isPhone ? Color(red: 0.1, green: 0.6, blue: 0.3) : (isLive ? Color(red: 0.0, green: 0.45, blue: 0.75) : Color.black.opacity(0.4)))
                            : (isPhone ? Color(red: 0.32, green: 0.9, blue: 0.62) : (isLive ? Color(red: 0.34, green: 0.68, blue: 1.0) : Color.white.opacity(0.45)))
                    )
                }

                ForEach(message.attachments) { attachment in
                    popoutAttachment(attachment)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 380, alignment: .leading)
            .background(popoutBubbleFill(message.role), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(message.role == .user ? 0.08 : 0.045), lineWidth: 1)
            )

            if message.role != .user {
                Spacer(minLength: 70)
            }
        }
    }

    private func popoutAttachment(_ attachment: NotchChatAttachment) -> some View {
        Button {
            NSWorkspace.shared.open(attachment.url)
        } label: {
            switch attachment.kind {
            case .localImage:
                if let image = NSImage(contentsOf: attachment.url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    popoutAttachmentChip(attachment)
                }
            case .remoteImage:
                AsyncImage(url: attachment.url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    default:
                        popoutAttachmentChip(attachment)
                    }
                }
            case .localVideo, .localFile, .localFolder, .remoteFile:
                popoutAttachmentChip(attachment)
            }
        }
        .buttonStyle(.plain)
    }

    private func popoutAttachmentChip(_ attachment: NotchChatAttachment) -> some View {
        HStack(spacing: 7) {
            Image(systemName: attachment.symbol)
            Text(attachment.title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.66))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.055), in: Capsule())
    }

    private func popoutBubbleFill(_ role: NotchChatRole) -> Color {
        switch role {
        case .user:
            return Color.white.opacity(0.88)
        case .assistant:
            return Color.white.opacity(0.07)
        case .system:
            return Color.white.opacity(0.04)
        }
    }
}

@MainActor
private final class NotchCameraController: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var authorizationDenied = false

    let session = AVCaptureSession()
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationDenied = false
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorizationDenied = !granted
                    if granted {
                        self.configureAndStart()
                    }
                }
            }
        case .denied, .restricted:
            authorizationDenied = true
            isRunning = false
        @unknown default:
            authorizationDenied = true
            isRunning = false
        }
    }

    func stop() {
        guard session.isRunning else {
            isRunning = false
            return
        }

        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    private func configureAndStart() {
        if !isConfigured {
            session.beginConfiguration()
            session.sessionPreset = .medium

            defer {
                session.commitConfiguration()
            }

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                authorizationDenied = true
                return
            }

            session.addInput(input)
            isConfigured = true
        }

        guard !session.isRunning else {
            isRunning = true
            return
        }

        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = session.isRunning
            }
        }
    }
}

private struct NotchCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CameraPreviewNSView else { return }
        view.previewLayer.session = session
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct NotchPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.52), value: configuration.isPressed)
    }
}

private struct ShelfBatchTile: View {
    @ObservedObject var state: AppState
    let batch: CaptureShelfBatch
    let accent: Color

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if batch.images.isEmpty, batch.clips.isEmpty, let text = batch.texts.first {
                    textTile(text)
                } else if batch.images.isEmpty, let clip = batch.clips.first {
                    clipTile(clip)
                } else {
                    ForEach(Array(batch.images.prefix(3).enumerated()).reversed(), id: \.offset) { index, image in
                        imageTile(image)
                            .offset(x: CGFloat(index) * 7, y: CGFloat(index) * 2)
                            .opacity(index == 0 ? 1 : 0.82)
                    }
                }
            }
            .frame(width: 88, height: 52, alignment: .topLeading)
            .padding(.trailing, batch.itemCount > 1 ? 16 : 0)

            if batch.itemCount > 1 {
                Text("\(batch.itemCount)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(width: 18, height: 18)
                    .background(accent, in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .offset(x: 4, y: -4)
            }

            if isHovering {
                HStack(spacing: 5) {
                    TileActionButton(title: "Preview batch", symbol: "eye") {
                        state.previewShelfBatch(id: batch.id)
                    }
                    TileActionButton(title: "AirDrop batch", symbol: "square.and.arrow.up") {
                        state.airDropShelfBatch(id: batch.id)
                    }
                    TileActionButton(title: "Save batch", symbol: "folder.badge.plus") {
                        state.saveShelfBatch(id: batch.id)
                    }
                    TileActionButton(title: "Clear batch", symbol: "xmark") {
                        state.clearShelfBatch(id: batch.id)
                    }
                }
                .padding(4)
                .background(Color.black.opacity(0.54), in: Capsule())
                .offset(x: 7, y: -7)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: 112, height: 58, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private func imageTile(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(2)
            .frame(width: 74, height: 48)
            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(accent.opacity(batch.itemCount > 1 ? 0.9 : 0.45), lineWidth: batch.itemCount > 1 ? 1.5 : 1)
            )
            .shadow(color: accent.opacity(isHovering ? 0.28 : 0.12), radius: isHovering ? 10 : 4, x: 0, y: 4)
            .onTapGesture {
                state.copyShelfImageToClipboard(image)
            }
            .onDrag {
                imageProvider(for: image)
            }
            .help("Drag out, or click to copy")
    }

    private func clipTile(_ url: URL) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.58))
            Image(systemName: "film.stack")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(accent.opacity(0.92))
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(Color.black.opacity(0.78))
                .frame(width: 18, height: 18)
                .background(accent, in: Circle())
                .offset(x: 24, y: 14)
        }
        .frame(width: 74, height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: accent.opacity(isHovering ? 0.28 : 0.12), radius: isHovering ? 10 : 4, x: 0, y: 4)
        .onTapGesture {
            state.previewLocalFile(url, title: "clip")
        }
        .onDrag {
            NSItemProvider(object: url as NSURL)
        }
        .help("Preview clip")
    }

    private func textTile(_ text: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.58))

            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(accent.opacity(0.95))

                Text(textPreview(text))
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(3)
                    .foregroundStyle(.white.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)
        }
        .frame(width: 74, height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: accent.opacity(isHovering ? 0.28 : 0.12), radius: isHovering ? 10 : 4, x: 0, y: 4)
        .onTapGesture {
            state.copyShelfTextToClipboard(text)
        }
        .onDrag {
            NSItemProvider(object: text as NSString)
        }
        .help("Drag text out, or click to copy")
    }

    private func textPreview(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 70 else { return collapsed }
        return String(collapsed.prefix(70)) + "..."
    }



    private func imageProvider(for image: NSImage) -> NSItemProvider {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return NSItemProvider(object: "Desk Agent shelf image unavailable." as NSString)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-shelf-\(UUID().uuidString).png")
        try? pngData.write(to: url, options: .atomic)

        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(pngData, nil)
            return nil
        }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, true, nil)
            return nil
        }
        return provider
    }
}

private struct NotchReminderItem: Identifiable, Hashable {
    let id: String
    let title: String
    let listName: String
    let dueDate: Date?

    var isOverdue: Bool {
        guard let dueDate else { return false }
        return dueDate < Date()
    }

    var subtitle: String {
        let dueText: String
        if let dueDate {
            dueText = Self.relativeDateFormatter.localizedString(for: dueDate, relativeTo: Date())
        } else {
            dueText = "No due date"
        }
        return "\(listName) - \(dueText)"
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct NotchCalendarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let calendarName: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let tint: Color

    var isNow: Bool {
        let now = Date()
        return startDate <= now && endDate >= now
    }

    var subtitle: String {
        let timeText = isAllDay ? "All day" : Self.timeFormatter.string(from: startDate)
        let dayText = Self.relativeDateFormatter.localizedString(for: startDate, relativeTo: Date())
        return "\(calendarName) - \(dayText), \(timeText)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

@MainActor
private final class NotchCalendarStore: ObservableObject {
    @Published private(set) var items: [NotchCalendarItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusTitle = "Apple Calendar"
    @Published private(set) var statusDetail = "Checking access"
    @Published private(set) var statusBadge = "Apple"
    @Published private(set) var statusSymbol = "calendar"
    @Published private(set) var tintColor = Color(red: 0.74, green: 0.56, blue: 1.0)
    @Published private(set) var emptyMessage = "No events loaded yet."

    private let store = EKEventStore()
    private var hasRequestedAccess = false

    func load() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if Self.isGranted(status) {
            fetchEvents()
            return
        }

        switch status {
        case .notDetermined:
            requestAccess()
        case .denied, .restricted:
            showPermissionBlocked()
        default:
            showPermissionBlocked()
        }
    }

    private func requestAccess() {
        guard !hasRequestedAccess else { return }
        hasRequestedAccess = true
        isLoading = true
        statusTitle = "Calendar access"
        statusDetail = "Waiting for permission"
        statusBadge = "allow"
        statusSymbol = "lock.open"
        emptyMessage = "Allow Calendar access when macOS asks."

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        }
    }

    private func handleAccessResult(_ granted: Bool) {
        isLoading = false
        if granted {
            fetchEvents()
        } else {
            showPermissionBlocked()
        }
    }

    private func fetchEvents() {
        isLoading = true
        statusTitle = "Loading calendar"
        statusDetail = "Reading Apple Calendar"
        statusBadge = "sync"
        statusSymbol = "arrow.clockwise"
        tintColor = Color(red: 0.74, green: 0.56, blue: 1.0)
        emptyMessage = "Checking Apple Calendar..."

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        apply(store.events(matching: predicate))
    }

    private func apply(_ events: [EKEvent]) {
        let mapped = events
            .filter { !$0.isDetached }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                NotchCalendarItem(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled event" : event.title,
                    calendarName: event.calendar.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    tint: Self.color(from: event.calendar.cgColor)
                )
            }

        items = Array(mapped.prefix(12))
        isLoading = false
        statusTitle = items.isEmpty ? "No events" : "\(items.count) event\(items.count == 1 ? "" : "s")"
        statusDetail = items.isEmpty ? "Apple Calendar is connected" : "Next 7 days"
        statusBadge = items.isEmpty ? "empty" : "\(items.count)"
        statusSymbol = items.isEmpty ? "checkmark.circle" : "calendar"
        tintColor = items.contains { $0.isNow } ? Color(red: 0.32, green: 0.9, blue: 0.62) : Color(red: 0.74, green: 0.56, blue: 1.0)
        emptyMessage = "No Apple Calendar events this week."
    }

    private func showPermissionBlocked() {
        items = []
        isLoading = false
        statusTitle = "Calendar blocked"
        statusDetail = "Allow access in Privacy"
        statusBadge = "blocked"
        statusSymbol = "lock.fill"
        tintColor = .orange
        emptyMessage = "Enable Calendar access for MarkShot in System Settings."
    }

    private static func isGranted(_ status: EKAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }
        if #available(macOS 14.0, *), status == .fullAccess {
            return true
        }
        return false
    }

    private static func color(from cgColor: CGColor?) -> Color {
        guard let cgColor else { return Color(red: 0.74, green: 0.56, blue: 1.0) }
        return Color(cgColor: cgColor)
    }
}

@MainActor
private final class NotchRemindersStore: ObservableObject {
    @Published private(set) var items: [NotchReminderItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusTitle = "Apple Reminders"
    @Published private(set) var statusDetail = "Checking access"
    @Published private(set) var statusBadge = "Apple"
    @Published private(set) var statusSymbol = "checklist"
    @Published private(set) var tintColor = Color(red: 0.42, green: 0.76, blue: 1.0)
    @Published private(set) var emptyMessage = "No reminders loaded yet."

    private let store = EKEventStore()
    private var hasRequestedAccess = false

    func load() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if Self.isGranted(status) {
            fetchReminders()
            return
        }

        switch status {
        case .notDetermined:
            requestAccess()
        case .denied, .restricted:
            showPermissionBlocked()
        default:
            showPermissionBlocked()
        }
    }

    private func requestAccess() {
        guard !hasRequestedAccess else { return }
        hasRequestedAccess = true
        isLoading = true
        statusTitle = "Reminders access"
        statusDetail = "Waiting for permission"
        statusBadge = "allow"
        statusSymbol = "lock.open"
        emptyMessage = "Allow Reminders access when macOS asks."

        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        } else {
            store.requestAccess(to: .reminder) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        }
    }

    private func handleAccessResult(_ granted: Bool) {
        isLoading = false
        if granted {
            fetchReminders()
        } else {
            showPermissionBlocked()
        }
    }

    private func fetchReminders() {
        isLoading = true
        statusTitle = "Loading reminders"
        statusDetail = "Reading Apple Reminders"
        statusBadge = "sync"
        statusSymbol = "arrow.clockwise"
        tintColor = Color(red: 0.42, green: 0.76, blue: 1.0)
        emptyMessage = "Checking Apple Reminders..."

        let dueBefore = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in
                self?.apply(reminders ?? [])
            }
        }
    }

    private func apply(_ reminders: [EKReminder]) {
        let mapped = reminders.map { reminder in
            NotchReminderItem(
                id: reminder.calendarItemIdentifier,
                title: reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled reminder" : reminder.title,
                listName: reminder.calendar.title,
                dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            )
        }
        .sorted { left, right in
            switch (left.dueDate, right.dueDate) {
            case let (leftDate?, rightDate?):
                return leftDate < rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
        }

        items = Array(mapped.prefix(20))
        isLoading = false
        statusTitle = items.isEmpty ? "No reminders" : "\(items.count) reminder\(items.count == 1 ? "" : "s")"
        statusDetail = items.isEmpty ? "Apple Reminders is connected" : "Next 30 days"
        statusBadge = items.isEmpty ? "empty" : "\(items.count)"
        statusSymbol = items.isEmpty ? "checkmark.circle" : "checklist"
        tintColor = items.contains { $0.isOverdue } ? Color(red: 1.0, green: 0.78, blue: 0.28) : Color(red: 0.32, green: 0.9, blue: 0.62)
        emptyMessage = "No incomplete reminders due soon."
    }

    private func showPermissionBlocked() {
        items = []
        isLoading = false
        statusTitle = "Reminders blocked"
        statusDetail = "Allow access in Privacy"
        statusBadge = "blocked"
        statusSymbol = "lock.fill"
        tintColor = .orange
        emptyMessage = "Enable Reminders access for MarkShot in System Settings."
    }

    private static func isGranted(_ status: EKAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }
        if #available(macOS 14.0, *), status == .fullAccess {
            return true
        }
        return false
    }
}

// MARK: - Custom Button Views

private struct DockActionButton: View {
    let title: String
    let symbol: String
    let module: NotchModule
    @Binding var activeModule: NotchModule
    
    @State private var isHovering = false
    @State private var wiggleScaleX: CGFloat = 1.0
    @State private var wiggleScaleY: CGFloat = 1.0
    @State private var wiggleRotation: Double = 0.0
    
    private var moduleColor: Color {
        switch module {
        case .home: return Color(white: 0.92)
        case .chat: return Color(red: 0.32, green: 0.9, blue: 0.62)
        case .notes: return Color(red: 0.34, green: 0.68, blue: 1.0)
        case .shelf: return Color(red: 1.0, green: 0.78, blue: 0.36)
        case .music: return Color(red: 0.75, green: 0.48, blue: 1.0)
        case .switchboard: return Color(red: 1.0, green: 0.72, blue: 0.28)
        }
    }
    
    private var isSelected: Bool {
        activeModule == module
    }
    
    private var foregroundColor: Color {
        if isSelected {
            return module == .home ? Color.black : Color.black.opacity(0.85)
        } else {
            return isHovering ? Color.white : Color.white.opacity(0.82)
        }
    }
    
    var body: some View {
        Button {
            activeModule = module
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .background {
                    ZStack {
                        if isSelected {
                            LinearGradient(
                                colors: [moduleColor, moduleColor.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else if isHovering {
                            Color.white.opacity(0.15)
                        } else {
                            Color.black.opacity(0.64)
                        }
                    }
                    .clipShape(Circle())
                }
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected
                                ? Color.white.opacity(0.24)
                                : (isHovering ? Color.white.opacity(0.18) : Color.white.opacity(0.07)),
                            lineWidth: 1
                        )
                )
                .scaleEffect(isHovering ? 1.12 : 1.0)
                .scaleEffect(x: wiggleScaleX, y: wiggleScaleY)
                .rotationEffect(.degrees(wiggleRotation))
                .shadow(
                    color: isSelected
                        ? moduleColor.opacity(0.36)
                        : (isHovering ? Color.white.opacity(0.15) : Color.clear),
                    radius: isSelected ? 8 : (isHovering ? 5 : 0),
                    x: 0,
                    y: 2
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
        .onChange(of: isSelected) { selected in
            if selected {
                wiggleScaleX = 1.25
                wiggleScaleY = 0.75
                wiggleRotation = 12.0
                withAnimation(.spring(response: 0.44, dampingFraction: 0.36)) {
                    wiggleScaleX = 1.0
                    wiggleScaleY = 1.0
                    wiggleRotation = 0.0
                }
            }
        }
    }
}

private struct RailActionButtonView: View {
    let title: String
    let symbol: String
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var clickScale: CGFloat = 1.0
    @State private var clickRotation: Double = 0.0
    
    var body: some View {
        Button(action: {
            action()
            clickScale = 1.28
            clickRotation = 12.0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.44)) {
                clickScale = 1.0
                clickRotation = 0.0
            }
        }) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovering ? .white : .white.opacity(0.55))
                .frame(width: 22, height: 22)
                .background {
                    (isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.035))
                        .clipShape(Circle())
                }
                .overlay(
                    Circle()
                        .strokeBorder(isHovering ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(clickScale)
                .rotationEffect(.degrees(clickRotation))
                .shadow(
                    color: isHovering ? Color.white.opacity(0.08) : Color.clear,
                    radius: isHovering ? 5 : 0
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }
}

private struct NotchControlButtonView: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let activeColor: Color
    let activePulse: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var wiggleScaleX: CGFloat = 1.0
    @State private var wiggleScaleY: CGFloat = 1.0
    @State private var wiggleRotation: Double = 0.0
    
    private var foregroundColor: Color {
        if isActive {
            return Color.black.opacity(0.85)
        } else {
            return isHovering ? Color.white : Color.white.opacity(0.74)
        }
    }
    
    private var activeShadowColor: Color {
        activeColor.opacity(activePulse ? 0.45 : 0.2)
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .background {
                    ZStack {
                        if isActive {
                            activeColor
                        } else if isHovering {
                            Color.white.opacity(0.14)
                        } else {
                            Color.white.opacity(0.065)
                        }
                    }
                    .clipShape(Circle())
                }
                .overlay(
                    Circle()
                        .strokeBorder(isActive ? Color.white.opacity(0.22) : (isHovering ? Color.white.opacity(0.18) : Color.white.opacity(0.08)), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(x: wiggleScaleX, y: wiggleScaleY)
                .rotationEffect(.degrees(wiggleRotation))
                .shadow(
                    color: isActive ? activeShadowColor : (isHovering ? Color.white.opacity(0.1) : Color.clear),
                    radius: isActive ? (activePulse ? 12 : 5) : (isHovering ? 6 : 0),
                    x: 0,
                    y: 0
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
        .onChange(of: isActive) { active in
            wiggleScaleX = 1.3
            wiggleScaleY = 0.7
            wiggleRotation = active ? 15.0 : -15.0
            withAnimation(.spring(response: 0.46, dampingFraction: 0.36)) {
                wiggleScaleX = 1.0
                wiggleScaleY = 1.0
                wiggleRotation = 0.0
            }
        }
    }
}

private struct SidecarSectionButton: View {
    let section: HermesSidecarSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var wiggleScaleX: CGFloat = 1.0
    @State private var wiggleScaleY: CGFloat = 1.0
    @State private var wiggleRotation: Double = 0.0

    private var foregroundColor: Color {
        if isSelected {
            return section == .system ? Color.black.opacity(0.82) : Color.black.opacity(0.85)
        }
        return isHovering ? Color.white : Color.white.opacity(0.66)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(foregroundColor)
                .frame(width: 34, height: 34)
                .background {
                    ZStack {
                        if isSelected {
                            LinearGradient(
                                colors: [section.accent, section.accent.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else if isHovering {
                            Color.white.opacity(0.14)
                        } else {
                            Color.white.opacity(0.045)
                        }
                    }
                    .clipShape(Circle())
                }
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected
                                ? Color.white.opacity(0.24)
                                : (isHovering ? Color.white.opacity(0.16) : Color.white.opacity(0.06)),
                            lineWidth: 1
                        )
                )
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .scaleEffect(x: wiggleScaleX, y: wiggleScaleY)
                .rotationEffect(.degrees(wiggleRotation))
                .shadow(
                    color: isSelected
                        ? section.accent.opacity(0.34)
                        : (isHovering ? Color.white.opacity(0.12) : Color.clear),
                    radius: isSelected ? 10 : (isHovering ? 5 : 0),
                    x: 0,
                    y: 2
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("\(section.title): \(section.subtitle)")
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
        .onChange(of: isSelected) { selected in
            if selected {
                wiggleScaleX = 1.28
                wiggleScaleY = 0.72
                wiggleRotation = 12.0
                withAnimation(.spring(response: 0.44, dampingFraction: 0.36)) {
                    wiggleScaleX = 1.0
                    wiggleScaleY = 1.0
                    wiggleRotation = 0.0
                }
            }
        }
    }
}

private struct ModuleIconButtonView: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var wiggleScaleX: CGFloat = 1.0
    @State private var wiggleScaleY: CGFloat = 1.0
    @State private var wiggleRotation: Double = 0.0
    
    private var foregroundColor: Color {
        if isActive {
            return Color.black.opacity(0.85)
        } else {
            return isHovering ? Color.white : Color.white.opacity(0.72)
        }
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .background {
                    ZStack {
                        if isActive {
                            Color.white.opacity(0.82)
                        } else if isHovering {
                            Color.white.opacity(0.14)
                        } else {
                            Color.white.opacity(0.065)
                        }
                    }
                    .clipShape(Circle())
                }
                .overlay(
                    Circle().strokeBorder(
                        isActive ? Color.white.opacity(0.18) : (isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.07)),
                        lineWidth: 1
                    )
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(x: wiggleScaleX, y: wiggleScaleY)
                .rotationEffect(.degrees(wiggleRotation))
                .shadow(
                    color: isHovering ? Color.white.opacity(0.08) : Color.clear,
                    radius: isHovering ? 5 : 0
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .onChange(of: isActive) { active in
            wiggleScaleX = 1.3
            wiggleScaleY = 0.7
            wiggleRotation = active ? 15.0 : -15.0
            withAnimation(.spring(response: 0.46, dampingFraction: 0.36)) {
                wiggleScaleX = 1.0
                wiggleScaleY = 1.0
                wiggleRotation = 0.0
            }
        }
    }
}

private struct MusicTrackRowView: View {
    let track: NotchMusicTrack
    let selectedTrackID: String?
    let accent: Color
    let action: () -> Void
    
    @State private var isHovering = false
    
    private var isSelected: Bool {
        selectedTrackID == track.id
    }
    
    private var iconColor: Color {
        isSelected ? accent : .white.opacity(isHovering ? 0.76 : 0.46)
    }
    
    private var textColor: Color {
        .white.opacity(isSelected ? 0.92 : (isHovering ? 0.85 : 0.68))
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "play.circle.fill" : "music.note")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(track.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(track.folderName)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(isHovering ? 0.45 : 0.28))
                    .lineLimit(1)
                    .frame(maxWidth: 72, alignment: .trailing)
            }
            .frame(height: 20)
            .padding(.horizontal, 7)
            .background {
                ZStack {
                    if isSelected {
                        Color.white.opacity(0.09)
                    } else if isHovering {
                        Color.white.opacity(0.06)
                    } else {
                        Color.white.opacity(0.035)
                    }
                }
                .clipShape(Capsule())
            }
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? accent.opacity(0.35) : (isHovering ? Color.white.opacity(0.07) : Color.clear), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(track.url.lastPathComponent)
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }
}

private struct MusicVisualizerView: View {
    let isPlaying: Bool
    let color: Color
    
    @State private var pulse = false
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: isPlaying ? (pulse ? 16 : 4) : 4)
                .animation(isPlaying ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: pulse)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: isPlaying ? (pulse ? 6 : 14) : 4)
                .animation(isPlaying ? .easeInOut(duration: 0.35).repeatForever(autoreverses: true) : .default, value: pulse)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: isPlaying ? (pulse ? 15 : 5) : 4)
                .animation(isPlaying ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: pulse)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: isPlaying ? (pulse ? 5 : 12) : 4)
                .animation(isPlaying ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .frame(width: 14, height: 16, alignment: .bottom)
        .onAppear {
            pulse = true
        }
    }
}

private struct MusicPlayButton: View {
    let isPlaying: Bool
    let activePulse: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var clickScale: CGFloat = 1.0
    @State private var clickRotation: Double = 0.0
    
    private var accentColor: Color {
        Color(red: 0.75, green: 0.48, blue: 1.0)
    }
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isPlaying {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accentColor.opacity(activePulse ? 0.32 : 0.08), lineWidth: 2)
                        .scaleEffect(activePulse ? 1.15 : 1.0)
                }
                
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isPlaying
                            ? LinearGradient(colors: [accentColor, Color(red: 0.34, green: 0.68, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isPlaying ? Color.black.opacity(0.85) : .white.opacity(0.72))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isHovering ? Color.white.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .frame(width: 42, height: 42)
            .scaleEffect(isHovering ? 1.06 : 1.0)
            .scaleEffect(clickScale)
            .rotationEffect(.degrees(clickRotation))
            .shadow(
                color: isPlaying ? accentColor.opacity(activePulse ? 0.42 : 0.22) : (isHovering ? Color.white.opacity(0.1) : Color.clear),
                radius: isPlaying ? (activePulse ? 10 : 5) : 5
            )
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .onChange(of: isPlaying) { playing in
            clickScale = 1.3
            clickRotation = playing ? 18.0 : -18.0
            withAnimation(.spring(response: 0.45, dampingFraction: 0.35)) {
                clickScale = 1.0
                clickRotation = 0.0
            }
        }
    }
}

private struct MusicMiniButtonView: View {
    let title: String
    let symbol: String
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var clickScale: CGFloat = 1.0
    @State private var clickRotation: Double = 0.0
    
    var body: some View {
        Button(action: {
            action()
            clickScale = 1.25
            clickRotation = 12.0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) {
                clickScale = 1.0
                clickRotation = 0.0
            }
        }) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovering ? .white : .white.opacity(0.62))
                .frame(width: 24, height: 20)
                .background(
                    isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.045),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.045), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(clickScale)
                .rotationEffect(.degrees(clickRotation))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }
}

private struct TileActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var clickScale: CGFloat = 1.0
    @State private var clickRotation: Double = 0.0
    
    var body: some View {
        Button(action: {
            action()
            clickScale = 1.25
            clickRotation = 12.0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) {
                clickScale = 1.0
                clickRotation = 0.0
            }
        }) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? .white : .white.opacity(0.78))
                .frame(width: 18, height: 18)
                .background(
                    isHovering ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                    in: Circle()
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .scaleEffect(clickScale)
                .rotationEffect(.degrees(clickRotation))
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }
}

private struct MusicMediaControlButton: View {
    let symbol: String
    let title: String
    let isPrimary: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var clickScale: CGFloat = 1.0
    @State private var clickRotation: Double = 0.0
    
    var body: some View {
        Button(action: {
            action()
            clickScale = isPrimary ? 1.15 : 1.25
            clickRotation = isPrimary ? (symbol.contains("pause") ? -12.0 : 12.0) : 15.0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) {
                clickScale = 1.0
                clickRotation = 0.0
            }
        }) {
            if isPrimary {
                ZStack {
                    Circle()
                        .fill(isHovering ? Color.white.opacity(0.95) : Color.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.white.opacity(isHovering ? 0.35 : 0.15), radius: 6, y: 2)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color.black)
                        .offset(x: symbol.contains("play") ? 1 : 0)
                }
                .scaleEffect(isHovering ? 1.12 : 1.0)
                .scaleEffect(clickScale)
                .rotationEffect(.degrees(clickRotation))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isHovering ? Color.white : Color.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(
                        isHovering ? Color.white.opacity(0.12) : Color.clear,
                        in: Circle()
                    )
                    .scaleEffect(isHovering ? 1.18 : 1.0)
                    .scaleEffect(clickScale)
                    .rotationEffect(.degrees(clickRotation))
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
    }
}

private struct MusicBrowserWebView: NSViewRepresentable {
    let desiredSource: MediaSource
    @ObservedObject var state: AppState

    func makeNSView(context: Context) -> WKWebView {
        if let existing = state.musicWebView {
            if !musicWebViewMatchesSource(existing, source: desiredSource),
               let url = URL(string: musicBrowseWebURL(for: desiredSource)) {
                existing.load(URLRequest(url: url))
            }
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        // Force Desktop User Agent so Spotify/Plex render standard desktop library view
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Zoom page out slightly so the desktop library UI fits the width nicely
        webView.pageZoom = 0.65

        if let url = URL(string: musicBrowseWebURL(for: desiredSource)) {
            webView.load(URLRequest(url: url))
        }

        state.musicWebView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard !musicWebViewMatchesSource(webView, source: desiredSource),
              let url = URL(string: musicBrowseWebURL(for: desiredSource))
        else { return }
        webView.load(URLRequest(url: url))
    }
}

private struct MiniMusicVisualizer: View {
    @ObservedObject var state: AppState
    let activePulse: Bool
    let mediaSource: MediaSource
    let visualizerHeights: [CGFloat]
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if state.notchPlaybackActive {
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { idx in
                            let rawHeight = visualizerHeights[idx % visualizerHeights.count]
                            let scaledHeight = 3.0 + (rawHeight - 4.0) * (11.0 / 22.0)
                            Capsule()
                                .fill(miniVisualizerColor)
                                .frame(width: 2.5, height: scaledHeight)
                        }
                    }
                    .frame(height: 14, alignment: .center)
                } else {
                    if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(miniVisualizerColor)
                    } else {
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { _ in
                                Capsule()
                                    .fill(miniVisualizerColor.opacity(0.42))
                                    .frame(width: 2.5, height: 4)
                            }
                        }
                    }
                }
            }
            .frame(width: 44, height: 24)
            .background(Color.black.opacity(0.0001))
            .scaleEffect(isHovering ? 1.08 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(state.notchPlaybackActive ? "Pause Music" : "Play Music")
    }
    
    private var miniVisualizerColor: Color {
        Color(red: 0.75, green: 0.48, blue: 1.0) // Premium purple
    }
}

extension View {
    @ViewBuilder
    fileprivate func applyHueRotationPhaseAnimator(active: Bool) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.phaseAnimator([0.0, 360.0]) { content, phase in
                content.hueRotation(.degrees(active ? phase : 0.0))
            } animation: { _ in
                .linear(duration: 4.0)
            }
        } else {
            self.modifier(HueRotationFallbackModifier(active: active))
        }
    }
}

private struct HueRotationFallbackModifier: ViewModifier {
    let active: Bool
    @State private var rotation: Double = 0.0
    
    func body(content: Content) -> some View {
        content
            .hueRotation(.degrees(rotation))
            .onAppear {
                if active {
                    withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                        rotation = 360.0
                    }
                }
            }
            .onChange(of: active) { newValue in
                if newValue {
                    withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                        rotation = 360.0
                    }
                } else {
                    rotation = 0.0
                }
            }
    }
}

// MARK: - Sidecar Layout Bezel-Blend Flares & Highlight Curves

private struct SidecarTopFlare: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        return path
    }
}

private struct SidecarBottomFlare: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        return path
    }
}

private struct SidecarTopCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        return path
    }
}

private struct SidecarBottomCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        return path
    }
}

// MARK: - Unified Sidecar Tab Lever Shapes

private struct SidecarLeverShape: Shape {
    let tabHeight: CGFloat
    let flareHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        path.move(to: CGPoint(x: w, y: 0))
        
        path.addQuadCurve(
            to: CGPoint(x: radius, y: flareHeight),
            control: CGPoint(x: w, y: flareHeight)
        )
        
        path.addQuadCurve(
            to: CGPoint(x: 0, y: flareHeight + radius),
            control: CGPoint(x: 0, y: flareHeight)
        )
        
        path.addLine(to: CGPoint(x: 0, y: h - flareHeight - radius))
        
        path.addQuadCurve(
            to: CGPoint(x: radius, y: h - flareHeight),
            control: CGPoint(x: 0, y: h - flareHeight)
        )
        
        path.addQuadCurve(
            to: CGPoint(x: w, y: h),
            control: CGPoint(x: w, y: h - flareHeight)
        )
        
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        return path
    }
}

private struct SidecarLeverOutline: Shape {
    let tabHeight: CGFloat
    let flareHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        path.move(to: CGPoint(x: w, y: 0))
        
        path.addQuadCurve(
            to: CGPoint(x: radius, y: flareHeight),
            control: CGPoint(x: w, y: flareHeight)
        )
        
        path.addQuadCurve(
            to: CGPoint(x: 0, y: flareHeight + radius),
            control: CGPoint(x: 0, y: flareHeight)
        )
        
        path.addLine(to: CGPoint(x: 0, y: h - flareHeight - radius))
        
        path.addQuadCurve(
            to: CGPoint(x: radius, y: h - flareHeight),
            control: CGPoint(x: 0, y: h - flareHeight)
        )
        
        path.addQuadCurve(
            to: CGPoint(x: w, y: h),
            control: CGPoint(x: w, y: h - flareHeight)
        )
        
        return path
    }
}
