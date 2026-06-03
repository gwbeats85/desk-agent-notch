import Foundation

enum MacFileOperationError: LocalizedError {
    case emptyName
    case invalidName
    case targetExists
    case missingParent
    case notDirectory
    case noItems
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Name cannot be empty."
        case .invalidName:
            return "Name cannot contain slashes or path separators."
        case .targetExists:
            return "An item with that name already exists."
        case .missingParent:
            return "The parent folder is not reachable."
        case .notDirectory:
            return "Choose a reachable folder."
        case .noItems:
            return "Select at least one item first."
        case .processFailed(let message):
            return message
        }
    }
}

enum MacFileOperationService {
    static func createFolder(in parent: URL, named name: String) throws -> URL {
        let target = try targetURL(in: parent, named: name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        guard let parent = url.parentDirectory else { throw MacFileOperationError.missingParent }
        let target = try targetURL(in: parent, named: newName)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func copyItems(_ urls: [URL], to destinationFolder: URL) throws -> [URL] {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { throw MacFileOperationError.noItems }
        try validateDestinationFolder(destinationFolder)

        return try fileURLs.map { url in
            let destination = uniqueSiblingURL(for: url, in: destinationFolder)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
    }

    static func moveItems(_ urls: [URL], to destinationFolder: URL) throws -> [URL] {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { throw MacFileOperationError.noItems }
        try validateDestinationFolder(destinationFolder)

        return try fileURLs.map { url in
            let destination = uniqueSiblingURL(for: url, in: destinationFolder)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    static func trashItems(_ urls: [URL]) throws -> [URL] {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { throw MacFileOperationError.noItems }

        return try fileURLs.compactMap { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        }
    }

    static func archive(_ urls: [URL], archiveName: String? = nil, destinationFolder: URL? = nil) throws -> URL {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { throw MacFileOperationError.noItems }

        let destinationFolder = destinationFolder ?? fileURLs[0].parentDirectory ?? FileManager.default.temporaryDirectory
        let archiveBaseName = sanitizeArchiveName(archiveName) ?? defaultArchiveName(for: fileURLs)
        let destination = uniqueURL(
            in: destinationFolder,
            basename: archiveBaseName,
            extension: "zip"
        )

        if fileURLs.count == 1 {
            try runDittoZip(source: fileURLs[0], destination: destination)
            return destination
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-agent-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for url in fileURLs {
            let target = uniqueURL(
                in: staging,
                basename: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension.isEmpty ? nil : url.pathExtension
            )
            try FileManager.default.copyItem(at: url, to: target)
        }

        try runDittoZip(source: staging, destination: destination)
        return destination
    }

    static func validateItemName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MacFileOperationError.emptyName }
        guard !name.contains("/"), !name.contains(":") else { throw MacFileOperationError.invalidName }
        return name
    }

    private static func targetURL(in parent: URL, named rawName: String) throws -> URL {
        let name = try validateItemName(rawName)
        let target = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MacFileOperationError.targetExists
        }
        return target
    }

    private static func validateDestinationFolder(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MacFileOperationError.notDirectory
        }
    }

    private static func uniqueSiblingURL(for source: URL, in folder: URL) -> URL {
        let basename = source.deletingPathExtension().lastPathComponent
        let pathExtension = source.pathExtension
        return uniqueURL(
            in: folder,
            basename: basename,
            extension: pathExtension.isEmpty ? nil : pathExtension
        )
    }

    private static func runDittoZip(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            source.path,
            destination.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacFileOperationError.processFailed(message ?? "Zip failed.")
        }
    }

    private static func sanitizeArchiveName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        return try? validateItemName(rawName.replacingOccurrences(of: ".zip", with: ""))
    }

    private static func defaultArchiveName(for urls: [URL]) -> String {
        if urls.count == 1 {
            return urls[0].deletingPathExtension().lastPathComponent
        }
        return "Desk Agent Archive"
    }

    private static func uniqueURL(in folder: URL, basename: String, extension pathExtension: String?) -> URL {
        let cleanBase = (try? validateItemName(basename)) ?? "Desk Agent Archive"
        var candidate = folder.appendingPathComponent(cleanBase)
        if let pathExtension, !pathExtension.isEmpty {
            candidate = candidate.appendingPathExtension(pathExtension)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        for index in 2...999 {
            var next = folder.appendingPathComponent("\(cleanBase) \(index)")
            if let pathExtension, !pathExtension.isEmpty {
                next = next.appendingPathExtension(pathExtension)
            }
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
        }

        var fallback = folder.appendingPathComponent("\(cleanBase) \(UUID().uuidString)")
        if let pathExtension, !pathExtension.isEmpty {
            fallback = fallback.appendingPathExtension(pathExtension)
        }
        return fallback
    }
}

private extension URL {
    var parentDirectory: URL? {
        let parent = deletingLastPathComponent()
        return parent.path == path ? nil : parent
    }
}
