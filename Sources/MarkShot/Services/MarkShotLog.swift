import Foundation

enum MarkShotLog {
    private static let defaultLogPath = "/tmp/markshot-debug.log"

    private static func resolvedLogURL() -> URL {
        return URL(fileURLWithPath: resolveLogPath())
    }

    private static func resolveLogPath() -> String {
        if let configuredPath = [
            envLogPath("MARKSHOT_LOG_PATH"),
            envLogPath("MARKSHOT_LOG")
        ].first(where: { !$0.isEmpty }) {
            if canWriteLog(at: configuredPath) {
                return configuredPath
            }
        }

        if canWriteLog(at: defaultLogPath) {
            return defaultLogPath
        }
        return defaultLogPath
    }

    private static func envLogPath(_ key: String) -> String {
        let raw = ProcessInfo.processInfo.environment[key] ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canWriteLog(at path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: path) {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return false
            }
            return fileManager.isWritableFile(atPath: path)
        } else {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        return fileManager.isWritableFile(atPath: directory.path)
    }

    private static var url: URL {
        return resolvedLogURL()
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if #available(macOS 10.15.4, *) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
