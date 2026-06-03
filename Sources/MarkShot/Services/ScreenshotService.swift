import AppKit

enum ScreenshotMode {
    case fullScreen
    case selectedRegion
    case window
}

enum ScreenshotError: LocalizedError {
    case cancelledOrBlocked
    case noImage
    case emptyRecording
    case processFailed(Int32, String?)
    case recordingAlreadyInProgress
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .cancelledOrBlocked:
            "Capture cancelled or blocked. If macOS asks, enable Screen Recording for Desk Agent in System Settings."
        case .noImage:
            "Capture finished, but no image was produced."
        case .emptyRecording:
            "Recording stopped, but no usable movie file was created."
        case .processFailed(let code, let detail):
            if let detail, !detail.isEmpty {
                "Capture failed with exit code \(code): \(detail)"
            } else {
                "Capture failed with exit code \(code). Check Screen Recording permission for Desk Agent."
            }
        case .recordingAlreadyInProgress:
            "A clip recording is already in progress."
        case .noActiveRecording:
            "No clip recording is active."
        }
    }
}

final class ScreenshotService {
    private static let recordingQueue = DispatchQueue(label: "com.deskagent.markshot.recording")
    private static var activeRecordingProcess: Process?
    private static var activeRecordingURL: URL?
    private static var activeRecordingCompletion: ((Result<URL, Error>) -> Void)?

    static func capture(mode: ScreenshotMode, completion: @escaping (Result<NSImage, Error>) -> Void) {
        if mode == .fullScreen {
            captureFullScreen(completion: completion)
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-capture-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments(for: mode, outputPath: url.path)
        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.processFailed(process.terminationStatus, errorText)))
                }
                return
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.cancelledOrBlocked))
                }
                return
            }

            guard let image = NSImage(contentsOf: url) else {
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.noImage))
                }
                return
            }

            DispatchQueue.main.async {
                completion(.success(image))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private static func arguments(for mode: ScreenshotMode, outputPath: String) -> [String] {
        switch mode {
        case .fullScreen:
            ["-x", outputPath]
        case .selectedRegion:
            ["-s", "-x", outputPath]
        case .window:
            ["-w", "-x", outputPath]
        }
    }

    static func recordClip(completion: @escaping (Result<URL, Error>) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-clip-\(UUID().uuidString).mov")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-i", "-s", "-Jvideo", "-x", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let canStart = recordingQueue.sync { () -> Bool in
            guard activeRecordingProcess == nil else { return false }
            activeRecordingProcess = process
            activeRecordingURL = url
            activeRecordingCompletion = completion
            return true
        }

        guard canStart else {
            completion(.failure(ScreenshotError.recordingAlreadyInProgress))
            return
        }

        process.terminationHandler = { p in
            let callback: ((Result<URL, Error>) -> Void)? = recordingQueue.sync {
                let current = activeRecordingCompletion
                activeRecordingProcess = nil
                activeRecordingURL = nil
                activeRecordingCompletion = nil
                return current
            }

            if FileManager.default.fileExists(atPath: url.path),
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value > 0 {
                DispatchQueue.main.async {
                    callback?(.success(url))
                }
                return
            }

            if p.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    callback?(.failure(ScreenshotError.processFailed(p.terminationStatus, errorText)))
                }
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async {
                    callback?(.failure(ScreenshotError.cancelledOrBlocked))
                }
                return
            }
            DispatchQueue.main.async {
                callback?(.failure(ScreenshotError.emptyRecording))
            }
        }

        do {
            try process.run()
        } catch {
            recordingQueue.sync {
                activeRecordingProcess = nil
                activeRecordingURL = nil
                activeRecordingCompletion = nil
            }
            completion(.failure(error))
        }
    }

    static func stopClipRecording() -> Result<URL, Error> {
        let active = recordingQueue.sync { () -> (Process?, URL?) in
            (activeRecordingProcess, activeRecordingURL)
        }

        guard let process = active.0, let url = active.1 else {
            return .failure(ScreenshotError.noActiveRecording)
        }

        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            recordingQueue.sync {
                if activeRecordingProcess === process, process.isRunning {
                    process.terminate()
                }
            }
        }
        return .success(url)
    }

    private static func captureFullScreen(completion: @escaping (Result<NSImage, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else {
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.cancelledOrBlocked))
                }
                return
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            DispatchQueue.main.async {
                completion(.success(image))
            }
        }
    }
}
