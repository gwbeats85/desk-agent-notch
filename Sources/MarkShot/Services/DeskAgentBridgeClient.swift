import Foundation

struct DeskAgentLiveReadiness: Equatable {
    let level: String
    let summary: String
    let nextStep: String
    let model: String
    let provider: String
    let authMode: String
    let hermesReady: Bool

    var isReady: Bool {
        level == "ready"
    }

    var compactStatus: String {
        if isReady {
            return "Talk ready"
        }
        if level == "blocked" {
            return "live session blocked"
        }
        if level == "offline" {
            return "live helper offline"
        }
        return summary.isEmpty ? "live helper unknown" : summary
    }
}

struct DeskAgentNotchStatus: Equatable {
    let pairedDevices: Int
    let pendingApprovals: Int
    let recentActions: [DeskAgentRecentAction]
    let airSends: [DeskAgentAirSend]
    let activeLiveSessions: [DeskAgentActiveLiveSession]
    let recentConversationTurns: [DeskAgentConversationTurn]
    let liveReadiness: DeskAgentLiveReadiness

    var compactStatus: String {
        if !activeLiveSessions.isEmpty {
            return "\(activeLiveSessions.count) live session\(activeLiveSessions.count == 1 ? "" : "s")"
        }
        if let latestTurn = recentConversationTurns.first, latestTurn.source == "iphone" {
            return latestTurn.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "phone heard" : "phone replied"
        }
        if pairedDevices > 0 {
            return "phone remembered"
        }
        if !airSends.isEmpty {
            return "AirSend waiting"
        }
        return "bridge ready"
    }
}

struct DeskAgentRecentAction: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let label: String
}

struct DeskAgentAirSend: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let text: String?
    let filePath: String?
    let previewUrl: String?
}

struct DeskAgentLiveDiagnostic: Decodable, Equatable {
    let event: String
    let detail: String
    let source: String
    let frameCount: Int?
    let at: String
}

struct DeskAgentActiveLiveSession: Decodable, Equatable, Identifiable {
    let id: String
    let provider: String
    let model: String
    let source: String?
    let conversationId: String?
    let startedAt: String?
    let lastDiagnostic: DeskAgentLiveDiagnostic?
}

struct DeskAgentConversationTurn: Decodable, Equatable, Identifiable {
    let id: String
    let source: String
    let conversationId: String?
    let text: String
    let response: String
    let backend: String
    let actionKind: String
    let at: String

    var isProofTurn: Bool {
        let normalizedConversation = (conversationId ?? "").lowercased()
        return normalizedConversation.contains("-proof-") ||
            normalizedConversation.hasPrefix("iphone-live-proof") ||
            normalizedConversation.hasPrefix("iphone-live-socket-proof") ||
            normalizedConversation.hasPrefix("iphone-live-tool-proof")
    }
}

struct DeskAgentLiveSession: Equatable {
    let id: String
    let provider: String
    let model: String
    let helperAuthToken: String
}

enum DeskAgentBridgeClientError: LocalizedError {
    case invalidResponse
    case helperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "DeskAgent helper returned an unreadable response."
        case let .helperUnavailable(message):
            return message
        }
    }
}

actor DeskAgentBridgeClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:4177")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchLiveReadiness() async throws -> DeskAgentLiveReadiness {
        guard let url = URL(string: "/api/live/config", relativeTo: baseURL)?.absoluteURL else {
            throw DeskAgentBridgeClientError.invalidResponse
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeskAgentBridgeClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DeskAgentBridgeClientError.helperUnavailable("DeskAgent helper returned HTTP \(httpResponse.statusCode).")
            }
            let decoded = try JSONDecoder().decode(LiveConfigResponse.self, from: data)
            return decoded.readiness.bridgeReadiness(
                provider: decoded.provider,
                model: decoded.model,
                authMode: decoded.authMode
            )
        } catch let error as DeskAgentBridgeClientError {
            throw error
        } catch {
            throw DeskAgentBridgeClientError.helperUnavailable(error.localizedDescription)
        }
    }

    func fetchNotchStatus() async throws -> DeskAgentNotchStatus {
        guard let url = URL(string: "/api/notch/status", relativeTo: baseURL)?.absoluteURL else {
            throw DeskAgentBridgeClientError.invalidResponse
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeskAgentBridgeClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DeskAgentBridgeClientError.helperUnavailable("DeskAgent helper returned HTTP \(httpResponse.statusCode).")
            }
            let decoded = try JSONDecoder().decode(NotchStatusResponse.self, from: data)
            let recentTurns = (decoded.conversation?.recentTurns ?? [])
                .filter { !$0.isProofTurn }
            return DeskAgentNotchStatus(
                pairedDevices: decoded.pairedDevices,
                pendingApprovals: decoded.pendingApprovals,
                recentActions: decoded.recentActions,
                airSends: decoded.airSends,
                activeLiveSessions: decoded.live.activeSessions ?? [],
                recentConversationTurns: recentTurns,
                liveReadiness: decoded.live.readiness.bridgeReadiness(
                    provider: decoded.live.provider,
                    model: decoded.live.model,
                    authMode: decoded.live.authMode
                )
            )
        } catch let error as DeskAgentBridgeClientError {
            throw error
        } catch {
            throw DeskAgentBridgeClientError.helperUnavailable(error.localizedDescription)
        }
    }

    func startLiveSession(machineId: String = "m5", learnMode: Bool = false, interactionMode: String = "autopilot") async throws -> DeskAgentLiveSession {
        guard let url = URL(string: "/api/live/session/start", relativeTo: baseURL)?.absoluteURL else {
            throw DeskAgentBridgeClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(StartLiveSessionRequest(
            machineId: machineId,
            learnMode: learnMode,
            interactionMode: interactionMode
        ))
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeskAgentBridgeClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DeskAgentBridgeClientError.helperUnavailable("DeskAgent helper returned HTTP \(httpResponse.statusCode).")
            }
            let decoded = try JSONDecoder().decode(StartLiveSessionResponse.self, from: data)
            return DeskAgentLiveSession(
                id: decoded.session.id,
                provider: decoded.session.provider,
                model: decoded.session.model,
                helperAuthToken: decoded.helperAuthToken
            )
        } catch let error as DeskAgentBridgeClientError {
            throw error
        } catch {
            throw DeskAgentBridgeClientError.helperUnavailable(error.localizedDescription)
        }
    }

    func endLiveSession(id: String, helperAuthToken: String) async throws {
        guard let url = URL(string: "/api/live/sessions/\(id)/end", relativeTo: baseURL)?.absoluteURL else {
            throw DeskAgentBridgeClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(helperAuthToken)", forHTTPHeaderField: "authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeskAgentBridgeClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DeskAgentBridgeClientError.helperUnavailable("DeskAgent helper returned HTTP \(httpResponse.statusCode).")
            }
        } catch let error as DeskAgentBridgeClientError {
            throw error
        } catch {
            throw DeskAgentBridgeClientError.helperUnavailable(error.localizedDescription)
        }
    }

    func consumeAirSend(id: String) async throws {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "/api/notch/airsend/\(encodedID)/consume", relativeTo: baseURL)?.absoluteURL
        else {
            throw DeskAgentBridgeClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeskAgentBridgeClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw DeskAgentBridgeClientError.helperUnavailable("DeskAgent helper returned HTTP \(httpResponse.statusCode).")
            }
        } catch let error as DeskAgentBridgeClientError {
            throw error
        } catch {
            throw DeskAgentBridgeClientError.helperUnavailable(error.localizedDescription)
        }
    }
}

private struct LiveConfigResponse: Decodable {
    let provider: String
    let model: String
    let authMode: String
    let readiness: ReadinessSummary
}

private struct NotchStatusResponse: Decodable {
    let pairedDevices: Int
    let pendingApprovals: Int
    let recentActions: [DeskAgentRecentAction]
    let airSends: [DeskAgentAirSend]
    let conversation: NotchStatusConversation?
    let live: NotchStatusLive
}

private struct NotchStatusConversation: Decodable {
    let recentTurns: [DeskAgentConversationTurn]
}

private struct NotchStatusLive: Decodable {
    let provider: String
    let model: String
    let authMode: String
    let activeSessions: [DeskAgentActiveLiveSession]?
    let readiness: ReadinessSummary
}

private struct StartLiveSessionRequest: Encodable {
    let machineId: String
    let learnMode: Bool
    let interactionMode: String
}

private struct StartLiveSessionResponse: Decodable {
    let session: LiveSessionRecord
    let helperAuthToken: String
}

private struct LiveSessionRecord: Decodable {
    let id: String
    let provider: String
    let model: String
}

private struct ReadinessSummary: Decodable {
    let level: String
    let summary: String
    let nextStep: String
    let checklist: [ReadinessItem]

    func bridgeReadiness(provider: String, model: String, authMode: String) -> DeskAgentLiveReadiness {
        let hermesReady = checklist.contains { item in
            item.id == "hermes" && item.status == "ready"
        }
        return DeskAgentLiveReadiness(
            level: level,
            summary: summary,
            nextStep: nextStep,
            model: model,
            provider: provider,
            authMode: authMode,
            hermesReady: hermesReady
        )
    }
}

private struct ReadinessItem: Decodable {
    let id: String
    let status: String
}
