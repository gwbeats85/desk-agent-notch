import AppKit

enum ScreenshotMode {
    case fullScreen
    case selectedRegion
    case window
}

enum ScreenshotError: LocalizedError {
    case cancelledOrBlocked
    case noImage
    case processFailed(Int32, String?)

    var errorDescription: String? {
        switch self {
        case .cancelledOrBlocked:
            "Capture cancelled or blocked. If macOS asks, enable Screen Recording for Desk Agent in System Settings."
        case .noImage:
            "Capture finished, but no image was produced."
        case .processFailed(let code, let detail):
            if let detail, !detail.isEmpty {
                "Capture failed with exit code \(code): \(detail)"
            } else {
                "Capture failed with exit code \(code). Check Screen Recording permission for Desk Agent."
            }
        }
    }
}

final class ScreenshotService {
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

        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.processFailed(p.terminationStatus, errorText)))
                }
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async {
                    completion(.failure(ScreenshotError.cancelledOrBlocked))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(url))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
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
