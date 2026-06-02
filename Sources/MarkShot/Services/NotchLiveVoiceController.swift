import Foundation
import WebKit

@MainActor
final class NotchLiveVoiceController: ObservableObject {
    @Published var pageReady = false
    @Published var liveState = "idle"
    @Published var warning = ""
    @Published var sessionId = ""
    @Published var provider = ""
    @Published var model = ""
    @Published var lastUserTranscript = ""
    @Published var lastAssistantTranscript = ""
    @Published var lastFinalUserTranscript = ""
    @Published var lastFinalAssistantTranscript = ""

    private weak var webView: WKWebView?

    var isActive: Bool {
        switch liveState {
        case "connecting", "listening", "thinking", "replying", "learn":
            return true
        default:
            return false
        }
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func start(conversationId: String) async {
        MarkShotLog.write("live start requested conversationId_prefix=\(conversationId.prefix(16))")
        resetTranscriptState()
        await evaluate(
            "window.DeskAgentLiveDefaults = { source: \"notch\", interactionMode: \"autopilot\", conversationId: conversationId }; window.DeskAgentLive && window.DeskAgentLive.start({ learnMode: false, interactionMode: \"autopilot\", source: \"notch\", conversationId: conversationId })",
            arguments: ["conversationId": conversationId]
        )
    }

    func stop() async {
        MarkShotLog.write("live stop requested")
        await evaluate("window.DeskAgentLive && window.DeskAgentLive.stop()")
    }

    func resetTranscriptState() {
        MarkShotLog.write("live transcript state reset")
        lastUserTranscript = ""
        lastAssistantTranscript = ""
        lastFinalUserTranscript = ""
        lastFinalAssistantTranscript = ""
    }

    private func isTranscriptFinal(_ value: Any?) -> Bool {
        guard let value else { return false }

        if let flag = value as? Bool {
            return flag
        }
        if let int = value as? Int {
            return int != 0
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        if let dict = value as? [String: Any] {
            return isTranscriptFinal(dict["final"]) ||
                isTranscriptFinal(dict["done"]) ||
                isTranscriptFinal(dict["isFinal"]) ||
                isTranscriptFinal(dict["is_final"]) ||
                isTranscriptFinal(dict["isDone"]) ||
                isTranscriptFinal(dict["is_done"]) ||
                isTranscriptFinal(dict["finished"]) ||
                isTranscriptFinal(dict["isFinalResult"]) ||
                isTranscriptFinal(dict["isFinalized"]) ||
                isTranscriptFinal(dict["is_finalized"]) ||
                isTranscriptFinal(dict["complete"]) ||
                isTranscriptFinal(dict["isComplete"]) ||
                isTranscriptFinal(dict["is_complete"]) ||
                isTranscriptFinal(dict["completed"]) ||
                isTranscriptFinal(dict["isCompleted"]) ||
                isTranscriptFinal(dict["is_completed"])
        }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes" || normalized == "y" || normalized == "final" || normalized == "done" || normalized == "finished" || normalized == "complete" || normalized == "completed"
        }
        return false
    }

    private func isTranscriptFinalPayload(_ payload: [String: Any]) -> Bool {
        isTranscriptFinal(payload["final"]) ||
            isTranscriptFinal(payload["done"]) ||
            isTranscriptFinal(payload["isFinal"]) ||
            isTranscriptFinal(payload["is_final"]) ||
            isTranscriptFinal(payload["isDone"]) ||
            isTranscriptFinal(payload["is_done"]) ||
            isTranscriptFinal(payload["finished"]) ||
            isTranscriptFinal(payload["isFinalResult"]) ||
            isTranscriptFinal(payload["isFinalized"]) ||
            isTranscriptFinal(payload["is_finalized"]) ||
            isTranscriptFinal(payload["complete"]) ||
            isTranscriptFinal(payload["isComplete"]) ||
            isTranscriptFinal(payload["is_complete"]) ||
            isTranscriptFinal(payload["completed"]) ||
            isTranscriptFinal(payload["isCompleted"]) ||
            isTranscriptFinal(payload["is_completed"])
    }

    func reloadBridge() {
        MarkShotLog.write("live bridge reload")
        pageReady = false
        warning = ""
        webView?.reload()
    }

    func handleBridgeMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String
        else {
            return
        }
        let isFinal = isTranscriptFinalPayload(payload)
        let bodyType = type

        switch type {
        case "page_ready":
            MarkShotLog.write("live bridge page_ready")
            pageReady = true
            if liveState == "offline" || liveState == "blocked" {
                liveState = "idle"
            }
            warning = ""
        case "state":
            let nextState = String(payload["state"] as? String ?? "idle")
            let detail = String(payload["detail"] as? String ?? "")
            MarkShotLog.write("live state -> \(nextState) detail=\(detail.prefix(180))")
            liveState = nextState
            warning = detail
        case "audio_diagnostic":
            let reason = String(payload["reason"] as? String ?? "unknown")
            let message = String(payload["message"] as? String ?? "")
            MarkShotLog.write("live audio_diagnostic reason=\(reason) message=\(message.prefix(180)) frameCount=\(payload["frameCount"] ?? "")")
        case "warning":
            MarkShotLog.write("live warning: \(String(payload["message"] as? String ?? "").prefix(80))")
            warning = String(payload["message"] as? String ?? "")
        case "session":
            MarkShotLog.write("live session id updated")
            sessionId = String(payload["sessionId"] as? String ?? sessionId)
            provider = String(payload["provider"] as? String ?? provider)
            model = String(payload["model"] as? String ?? model)
        case "user_transcript":
            let incomingText = String(payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingText.isEmpty {
                lastUserTranscript = incomingText
                MarkShotLog.write("live user_transcript final=\(isFinal) len=\(incomingText.count)")
                if isFinal {
                    lastFinalUserTranscript = incomingText
                }
            } else if isFinal && !lastUserTranscript.isEmpty {
                MarkShotLog.write("live user_transcript final(empty) len=\(lastUserTranscript.count)")
                lastFinalUserTranscript = lastUserTranscript
            } else {
                MarkShotLog.write("live user_transcript final=\(isFinal) len=0 ignored")
            }
        case "assistant_transcript":
            let incomingText = String(payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingText.isEmpty {
                lastAssistantTranscript = incomingText
                MarkShotLog.write("live assistant_transcript final=\(isFinal) len=\(incomingText.count)")
                if isFinal {
                    lastFinalAssistantTranscript = incomingText
                }
            } else if isFinal && !lastAssistantTranscript.isEmpty {
                MarkShotLog.write("live assistant_transcript final(empty) len=\(lastAssistantTranscript.count)")
                lastFinalAssistantTranscript = lastAssistantTranscript
            } else {
                MarkShotLog.write("live assistant_transcript final=\(isFinal) len=0 ignored")
            }
        default:
            MarkShotLog.write("live bridge type=\(bodyType)")
        }
    }

    func markBridgeUnavailable(_ message: String) {
        MarkShotLog.write("live bridge unavailable: \(message)")
        pageReady = false
        liveState = "offline"
        warning = message
    }

    private func evaluate(_ script: String, arguments: [String: Any] = [:]) async {
        guard let webView else {
            MarkShotLog.write("live evaluate blocked: bridge not loaded")
            warning = "Live voice web bridge is not loaded yet."
            return
        }
        do {
            _ = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            MarkShotLog.write("live evaluate failed: \(error.localizedDescription)")
            warning = error.localizedDescription
            liveState = "blocked"
        }
    }
}
