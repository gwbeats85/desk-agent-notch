import AppKit
import Darwin
import Foundation

enum VideoFrameLabError: LocalizedError {
    case missingWorkspace(URL)
    case startFailed
    case uploadFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingWorkspace(let url):
            "VideoFrame Lab folder was not found at \(url.path)."
        case .startFailed:
            "Could not start VideoFrame Lab."
        case .uploadFailed(let detail):
            "VideoFrame upload failed: \(detail)"
        case .invalidResponse:
            "VideoFrame Lab returned an unexpected response."
        }
    }
}

struct VideoFrameImportResult {
    let jobId: String
    let url: URL
}

final class VideoFrameLabService {
    static let shared = VideoFrameLabService()

    private static let fallbackPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private let preferredPort = 3000
    private var currentPort = 3000
    private let workspaceURL: URL = {
        if let configured = ProcessInfo.processInfo.environment["MARKSHOT_VIDEOFRAME_LAB_PATH"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/VideoFrameLab", isDirectory: true)
    }()
    private var process: Process?
    private var idleStopTimer: Timer?

    var baseURL: URL {
        URL(string: "http://localhost:\(currentPort)")!
    }

    private init() {}

    func openLab() {
        Task {
            do {
                try await ensureRunning()
                _ = await MainActor.run {
                    NSWorkspace.shared.open(baseURL)
                }
            } catch {
                _ = await MainActor.run {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    func stop() {
        idleStopTimer?.invalidate()
        idleStopTimer = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    func ensureRunning() async throws {
        if await isHealthy() {
            scheduleIdleStop()
            return
        }

        try start()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if await isHealthy() {
                scheduleIdleStop()
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        throw VideoFrameLabError.startFailed
    }

    func importClip(_ clipURL: URL) async throws -> VideoFrameImportResult {
        try await ensureRunning()

        let uploadURL = baseURL.appendingPathComponent("api/upload")
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"

        let boundary = "MarkShotBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: clipURL)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(clipURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: video/quicktime\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoFrameLabError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "status \(httpResponse.statusCode)"
            throw VideoFrameLabError.uploadFailed(detail)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let jobId = json["jobId"] as? String
        else {
            throw VideoFrameLabError.invalidResponse
        }

        scheduleIdleStop()
        let jobURL = URL(string: "\(baseURL.absoluteString)?jobId=\(jobId)")!
        return VideoFrameImportResult(jobId: jobId, url: jobURL)
    }

    private func start() throws {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw VideoFrameLabError.missingWorkspace(workspaceURL)
        }

        if let process, process.isRunning {
            return
        }

        currentPort = Self.availablePort(startingAt: preferredPort)

        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("markshot-videoframe-lab.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let nextProcess = Process()
        nextProcess.currentDirectoryURL = workspaceURL
        nextProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        nextProcess.arguments = ["npm", "run", "dev"]
        nextProcess.environment = launchEnvironment(forPort: currentPort)

        if let logHandle {
            nextProcess.standardOutput = logHandle
            nextProcess.standardError = logHandle
        }

        try nextProcess.run()
        process = nextProcess
    }

    private static func availablePort(startingAt port: Int) -> Int {
        for candidate in port...(port + 20) where !isPortListening(candidate) && canBind(port: candidate) {
            return candidate
        }
        return port
    }

    private static func isPortListening(_ port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func canBind(port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var reuse = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        request.timeoutInterval = 1.2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func scheduleIdleStop() {
        DispatchQueue.main.async {
            self.idleStopTimer?.invalidate()
            self.idleStopTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
                self?.stop()
            }
        }
    }

    private func launchEnvironment(forPort port: Int) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = "\(port)"

        var pathEntries = Self.fallbackPathEntries
        if let existingPath = environment["PATH"] {
            for entry in existingPath.split(separator: ":").map(String.init) where !pathEntries.contains(entry) {
                pathEntries.append(entry)
            }
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
