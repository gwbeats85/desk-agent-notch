import Foundation

struct HermesTurnResult {
    let response: String
    let sessionId: String
}

enum HermesDirectClientError: LocalizedError {
    case commandMissing
    case invocationFailed(String)
    case emptyResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .commandMissing:
            return "Hermes is not installed where Desk Agent expects it."
        case let .invocationFailed(message):
            return "Hermes failed: \(message)"
        case .emptyResponse:
            return "Hermes returned an empty reply."
        case .timedOut:
            return "Hermes timed out. Try again in a minute."
        }
    }
}

private struct HermesCommand {
    let executable: String
    let wrapperName: String
    let usesProfileWrapper: Bool

    var profileName: String? {
        usesProfileWrapper ? wrapperName : nil
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaim else { return false }
        didClaim = true
        return true
    }
}

actor HermesDirectClient {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func sendMessage(_ prompt: String, resumeSessionId: String?, imagePath: String? = nil) async throws -> HermesTurnResult {
        let command = try resolveCommand()
        let executable = command.usesProfileWrapper ? resolvedHermesExecutable() : command.executable
        var arguments = ["chat", "-Q"]

        if let profileName = command.profileName {
            arguments.insert(contentsOf: ["-p", profileName], at: 0)
        }

        if let provider = configuredValue("MARKSHOT_HERMES_PROVIDER", fallback: "openrouter") {
            arguments.append(contentsOf: ["--provider", provider])
        }
        if let model = configuredValue("MARKSHOT_HERMES_MODEL", fallback: "google/gemini-2.5-flash") {
            arguments.append(contentsOf: ["--model", model])
        }

        if let resumeSessionId, !resumeSessionId.isEmpty {
            arguments.append(contentsOf: ["--resume", resumeSessionId])
        } else {
            arguments.append(contentsOf: ["--source", "tool"])
        }
        if let imagePath, !imagePath.isEmpty {
            arguments.append(contentsOf: ["--image", imagePath])
        }
        arguments.append(contentsOf: ["--query", prompt])

        let output = try await runProcess(
            executable: executable,
            arguments: arguments,
            extraEnvironment: ["NO_COLOR": "1"]
        )

        let sessionId = firstMatch(in: "\(output.stderr)\n\(output.stdout)", pattern: #"session_id:\s*(\S+)"#) ?? resumeSessionId ?? ""
        let response = output.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("↻ Resumed session ") }
            .filter { !$0.hasPrefix("session_id:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !response.isEmpty else {
            throw HermesDirectClientError.emptyResponse
        }

        return HermesTurnResult(response: response, sessionId: sessionId)
    }

    private func resolveCommand() throws -> HermesCommand {
        if let configured = environment["MARKSHOT_HERMES_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return HermesCommand(
                executable: configured,
                wrapperName: URL(fileURLWithPath: configured).lastPathComponent,
                usesProfileWrapper: !configured.hasSuffix("/hermes")
            )
        }

        let home = NSHomeDirectory()
        let hermes = resolvedHermesExecutable()
        if FileManager.default.isExecutableFile(atPath: hermes) {
            return HermesCommand(executable: hermes, wrapperName: "hermes", usesProfileWrapper: false)
        }

        let designpartner = "\(home)/.local/bin/designpartner"
        if FileManager.default.isExecutableFile(atPath: designpartner) {
            return HermesCommand(executable: designpartner, wrapperName: "designpartner", usesProfileWrapper: true)
        }

        throw HermesDirectClientError.commandMissing
    }

    private func resolvedHermesExecutable() -> String {
        "\(NSHomeDirectory())/.local/bin/hermes"
    }

    private func configuredValue(_ key: String, fallback: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        return value.isEmpty ? nil : value
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let gate = ContinuationGate()

            @Sendable func finish(_ result: Result<(stdout: String, stderr: String), Error>) {
                guard gate.claim() else { return }
                switch result {
                case let .success(output):
                    continuation.resume(returning: output)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = environment.merging(extraEnvironment) { _, new in new }

            process.terminationHandler = { process in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    finish(.success((stdout, stderr)))
                } else {
                    let stderrLines = stderr
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("session_id:") }
                    let stdoutLines = stdout
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let detail = (stderrLines + stdoutLines).first ?? "exit_\(process.terminationStatus)"
                    finish(.failure(HermesDirectClientError.invocationFailed(detail)))
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
                    guard process.isRunning else { return }
                    process.terminate()
                    finish(.failure(HermesDirectClientError.timedOut))
                }
            } catch {
                finish(.failure(HermesDirectClientError.invocationFailed(error.localizedDescription)))
            }
        }
    }
}
