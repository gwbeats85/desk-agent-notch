import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct CaptureShelfBatch: Identifiable {
    let id = UUID()
    var images: [NSImage] = []
    var clips: [URL] = []
    let createdAt: Date

    var itemCount: Int {
        images.count + clips.count
    }

    var hasClips: Bool {
        !clips.isEmpty
    }
}

private final class ShelfQuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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

@MainActor
final class AppState: ObservableObject {
    private static let maxShelfBatches = 12

    @Published var baseImage: NSImage?
    @Published var annotations: [Annotation] = []
    @Published var redoStack: [Annotation] = []
    @Published var selectedTool: AnnotationTool = .arrow
    @Published var selectedColor: NSColor = .systemRed
    @Published var strokeWidth: CGFloat = 5
    @Published var statusMessage = "Capture a screenshot to start."
    @Published var isCapturing = false
    @Published var isBoard = false
    @Published var pinnedCount = 0
    @Published var captureThumbnailCount = 0
    @Published var isRecordingClip = false
    @Published var isSendingClipToVideoFrame = false
    @Published var isVideoFrameLabActive = false
    @Published var lastRecordedClipURL: URL?
    @Published var shelfBatches: [CaptureShelfBatch] = []
    @Published var notchListeningEnabled = false
    @Published var notchPlaybackActive = false
    @Published var notchShelfExpanded = false
    
    // Shared persistent WKWebView for music browsing to prevent reloads when Notch is minimized/expanded
    var musicWebView: WKWebView?

    private var pinnedControllers: [PinnedScreenshotWindowController] = []
    private var captureThumbnailControllers: [CaptureThumbnailWindowController] = []
    private var shelfWindowController: NotchShelfWindowController?
    private var quickLookPreviewController: ShelfQuickLookPreviewController?
    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MarkShotMainWindow")

    init() {
        NotificationCenter.default.addObserver(
            forName: .markShotCaptureRegion,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureSelectedRegion()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotCaptureFullScreen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureFullScreen()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotCaptureWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureWindow()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotNewBoard,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.newBoard()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotShowToolbar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showToolbar()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotHideToolbar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideToolbar()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotHotkeyStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.object as? String else { return }
            Task { @MainActor in
                self?.statusMessage = message
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotRecordClip,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recordClip()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotClearPinned,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearAllPinned()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotSaveAllCaptureThumbnails,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveAllCaptureThumbnails()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotOpenVideoFrameLab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openVideoFrameLab()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotStopVideoFrameLab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopVideoFrameLab()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotShowNotchShelf,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showNotchShelf()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .markShotAirDropLatestShelf,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.airDropLatestShelfBatch()
            }
        }
    }

    func captureFullScreen() {
        capture(mode: .fullScreen)
    }

    func captureSelectedRegion() {
        capture(mode: .selectedRegion)
    }

    func captureWindow() {
        capture(mode: .window)
    }

    func newBoard() {
        baseImage = Self.boardImage(size: NSSize(width: 1600, height: 1000))
        annotations.removeAll()
        redoStack.removeAll()
        selectedTool = .pointer
        selectedColor = .systemRed
        strokeWidth = 5
        isBoard = true
        statusMessage = "Board ready. Drag layout blocks or markup, then copy/save."
        showToolbar()
    }

    private func capture(mode: ScreenshotMode) {
        isCapturing = true
        MarkShotLog.write("capture requested: \(mode)")
        statusMessage = "Hiding Desk Agent for capture..."
        hideForCapture()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ScreenshotService.capture(mode: mode) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isCapturing = false

                    switch result {
                    case .success(let image):
                        MarkShotLog.write("capture success: \(image.size.width)x\(image.size.height)")
                        NSApp.unhide(nil)
                        self.addCaptureThumbnail(image)
                        self.hideToolbar()
                        self.statusMessage = "Captured. Click the thumbnail to edit, or copy it from the hover controls."
                    case .failure(let error):
                        MarkShotLog.write("capture failed: \(error.localizedDescription)")
                        self.statusMessage = error.localizedDescription
                        self.showToolbar()
                    }
                }
            }
        }
    }

    func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
        statusMessage = "Annotation added."
    }

    func undo() {
        guard let item = annotations.popLast() else { return }
        redoStack.append(item)
        statusMessage = "Undone."
    }

    func redo() {
        guard let item = redoStack.popLast() else { return }
        annotations.append(item)
        statusMessage = "Redone."
    }

    func clearAnnotations() {
        annotations.removeAll()
        redoStack.removeAll()
        statusMessage = "Annotations cleared."
    }

    // MARK: - Pin to Screen

    func pinCurrentScreenshot() {
        guard let image = renderedImage() else {
            statusMessage = "Nothing to pin yet."
            return
        }
        let controller = PinnedScreenshotWindowController(image: image)
        controller.onClose = { [weak self] id in
            Task { @MainActor in
                self?.removePinned(id: id)
            }
        }
        pinnedControllers.append(controller)
        pinnedCount = pinnedControllers.count
        statusMessage = "Pinned. \(pinnedCount) screenshot\(pinnedCount == 1 ? "" : "s") on screen."
    }

    private func removePinned(id: UUID) {
        if let index = pinnedControllers.firstIndex(where: { $0.id == id }) {
            pinnedControllers[index].close()
            pinnedControllers.remove(at: index)
            pinnedCount = pinnedControllers.count
        }
    }

    func clearAllPinned() {
        pinnedControllers.forEach { $0.close() }
        pinnedControllers.removeAll()
        pinnedCount = 0
        statusMessage = "All pins cleared."
    }

    // MARK: - Capture Thumbnails

    private func addCaptureThumbnail(_ image: NSImage) {
        MarkShotLog.write("thumbnail add requested")
        let controller = CaptureThumbnailWindowController(
            image: image,
            stackIndex: captureThumbnailControllers.count
        )

        controller.onOpen = { [weak self] id, image in
            Task { @MainActor in
                self?.openThumbnailForEditing(id: id, image: image)
            }
        }
        controller.onCopy = { [weak self] image in
            Task { @MainActor in
                self?.copyImageToClipboard(image)
            }
        }
        controller.onSaveAll = { [weak self] in
            Task { @MainActor in
                self?.saveAllCaptureThumbnails()
            }
        }
        controller.onShelf = { [weak self] in
            Task { @MainActor in
                self?.sendCaptureStackToShelf()
            }
        }
        controller.onClose = { [weak self] id in
            Task { @MainActor in
                self?.removeCaptureThumbnail(id: id)
            }
        }

        captureThumbnailControllers.append(controller)
        captureThumbnailCount = captureThumbnailControllers.count
        MarkShotLog.write("thumbnail added count=\(captureThumbnailCount)")
    }

    private func openThumbnailForEditing(id: UUID, image: NSImage) {
        removeCaptureThumbnail(id: id)
        baseImage = image
        isBoard = false
        annotations.removeAll()
        redoStack.removeAll()
        selectedTool = .arrow
        selectedColor = .systemRed
        strokeWidth = 5
        statusMessage = "Captured. Use the bottom toolbar, then Cmd+C to copy."
        showToolbar()
    }

    private func removeCaptureThumbnail(id: UUID) {
        if let index = captureThumbnailControllers.firstIndex(where: { $0.id == id }) {
            captureThumbnailControllers[index].close()
            captureThumbnailControllers.remove(at: index)
            captureThumbnailCount = captureThumbnailControllers.count
            restackCaptureThumbnails()
        }
    }

    func sendCaptureStackToShelf() {
        guard !captureThumbnailControllers.isEmpty else {
            statusMessage = "No capture stack to send to the shelf."
            showNotchShelf()
            return
        }

        let images = captureThumbnailControllers.map(\.image)
        let batch = CaptureShelfBatch(images: images, createdAt: Date())
        prependShelfBatch(batch)
        captureThumbnailControllers.forEach { $0.close() }
        captureThumbnailControllers.removeAll()
        captureThumbnailCount = 0
        statusMessage = "Sent \(images.count) screenshot\(images.count == 1 ? "" : "s") to the notch shelf."
        ensureShelfWindow().showExpanded()
    }

    func showNotchShelf() {
        MarkShotLog.write("show notch shelf requested batches=\(shelfBatches.count)")
        let controller = ensureShelfWindow()
        if shelfBatches.isEmpty {
            controller.showCollapsed()
        } else {
            controller.show()
        }
    }

    func toggleNotchListening() {
        notchListeningEnabled.toggle()
        statusMessage = notchListeningEnabled ? "Notch listening is on." : "Notch listening is off."
        showNotchShelf()
    }

    func toggleNotchPlayback() {
        notchPlaybackActive.toggle()
        statusMessage = notchPlaybackActive ? "Notch playback is running." : "Notch playback stopped."
        showNotchShelf()
    }

    func runNotchCommand(_ prompt: String) {
        let command = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !command.isEmpty else {
            toggleNotchListening()
            return
        }

        if command.contains("copy") && command.contains("shelf") {
            copyLatestShelfBatchToClipboard()
        } else if command.contains("clear") && command.contains("shelf") {
            clearShelf()
        } else if command.contains("shelf") || command.contains("tray") {
            showNotchShelf()
            notchShelfExpanded = true
            statusMessage = shelfBatches.isEmpty ? "Shelf is empty." : "\(shelfBatches.count) shelf batch\(shelfBatches.count == 1 ? "" : "es") ready."
        } else if command.contains("board") {
            newBoard()
        } else if command.contains("clip") || command.contains("record") || command.contains("video") {
            recordClip()
        } else if command.contains("full") && (command.contains("screen") || command.contains("shot") || command.contains("capture")) {
            captureFullScreen()
        } else if command.contains("screen") || command.contains("shot") || command.contains("capture") {
            captureSelectedRegion()
        } else {
            copyTextToClipboard(prompt)
            statusMessage = "Copied notch note to clipboard."
        }
    }

    func saveQuickNoteToObsidian(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Nothing to save."
            return
        }

        do {
            try Self.appendQuickNoteToObsidian(trimmed)
            statusMessage = "Saved note to Obsidian inbox."
        } catch {
            statusMessage = "Obsidian save failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    static func appendQuickNoteToObsidian(_ note: String) throws -> URL {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let inbox = obsidianInboxDirectory()
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let fileURL = inbox.appendingPathComponent("markshot-quick-notes.md")
        let entry = obsidianQuickNoteEntry(trimmed)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
            try handle.close()
        } else {
            let header = "# Desk Agent Quick Notes\n\n"
            try Data((header + entry).utf8).write(to: fileURL, options: .atomic)
        }

        return fileURL
    }

    func hideNotchShelf() {
        shelfWindowController?.hide()
    }

    func clearShelfBatch(id: UUID) {
        shelfBatches.removeAll { $0.id == id }
        statusMessage = shelfBatches.isEmpty ? "Shelf cleared." : "Shelf batch removed."
        if shelfBatches.isEmpty {
            shelfWindowController?.refreshPosition(expanded: false)
        }
    }

    func clearShelf() {
        shelfBatches.removeAll()
        statusMessage = "Shelf cleared."
    }

    func copyShelfImageToClipboard(_ image: NSImage) {
        copyImageToClipboard(image)
    }

    func copyLatestShelfBatchToClipboard() {
        guard let batch = shelfBatches.first else {
            statusMessage = "Shelf is empty."
            showNotchShelf()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = batch.images
        objects.append(contentsOf: batch.clips.map { $0 as NSURL })
        pasteboard.writeObjects(objects)
        statusMessage = "Copied \(batch.itemCount) shelf item\(batch.itemCount == 1 ? "" : "s") to clipboard."
    }

    func saveShelfBatch(id: UUID) {
        guard let batch = shelfBatches.first(where: { $0.id == id }) else { return }

        let panel = NSOpenPanel()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.defaultScreenshotsDirectory()
        panel.prompt = "Save Batch"
        panel.message = "Choose a folder for this shelf batch."

        guard panel.runModal() == .OK, let folder = panel.url else {
            statusMessage = "Shelf batch save cancelled."
            return
        }

        let timestamp = Self.timestamp()
        var savedCount = 0
        for (index, image) in batch.images.enumerated() {
            guard let pngData = Self.pngData(from: image) else { continue }
            let filename = "markshot-shelf-\(timestamp)-\(String(format: "%02d", index + 1)).png"
            let url = folder.appendingPathComponent(filename)
            do {
                try pngData.write(to: url, options: .atomic)
                savedCount += 1
            } catch {
                statusMessage = "Shelf batch save failed: \(error.localizedDescription)"
                return
            }
        }
        for clip in batch.clips {
            let filename = "markshot-clip-\(timestamp)-\(clip.lastPathComponent)"
            let destination = folder.appendingPathComponent(filename)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: clip, to: destination)
                savedCount += 1
            } catch {
                statusMessage = "Shelf clip save failed: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "Saved \(savedCount) shelf item\(savedCount == 1 ? "" : "s")."
    }

    func previewLatestShelfBatch() {
        guard let batch = shelfBatches.first else {
            statusMessage = "Shelf is empty."
            showNotchShelf()
            return
        }
        previewShelfBatch(id: batch.id)
    }

    func previewShelfBatch(id: UUID) {
        guard let batch = shelfBatches.first(where: { $0.id == id }) else {
            statusMessage = "Shelf batch is gone."
            return
        }

        do {
            let urls = try temporaryShelfFiles(for: batch, prefix: "quicklook")
            guard !urls.isEmpty else {
                statusMessage = "No shelf items to preview."
                return
            }

            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            let controller = ShelfQuickLookPreviewController(urls: urls)
            quickLookPreviewController = controller
            controller.show()
            statusMessage = "Previewing \(urls.count) shelf item\(urls.count == 1 ? "" : "s")."
        } catch {
            statusMessage = "Preview prep failed: \(error.localizedDescription)"
        }
    }

    func previewLocalFile(_ url: URL, title: String = "attachment") {
        guard url.isFileURL else {
            NSWorkspace.shared.open(url)
            statusMessage = "Opening \(title)."
            return
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let controller = ShelfQuickLookPreviewController(urls: [url])
        quickLookPreviewController = controller
        controller.show()
        statusMessage = "Previewing \(title)."
    }

    func airDropLatestShelfBatch() {
        guard let batch = shelfBatches.first else {
            statusMessage = "Shelf is empty."
            showNotchShelf()
            return
        }
        airDropShelfBatch(id: batch.id)
    }

    func airDropShelfBatch(id: UUID) {
        guard let batch = shelfBatches.first(where: { $0.id == id }) else {
            statusMessage = "Shelf batch is gone."
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            statusMessage = "AirDrop is not available on this Mac."
            return
        }

        do {
            let urls = try temporaryShelfFiles(for: batch, prefix: "airdrop")

            guard !urls.isEmpty else {
                statusMessage = "No shelf items to AirDrop."
                return
            }

            NSApp.unhide(nil)
            service.perform(withItems: urls)
            statusMessage = "AirDrop ready for \(urls.count) shelf item\(urls.count == 1 ? "" : "s")."
        } catch {
            statusMessage = "AirDrop prep failed: \(error.localizedDescription)"
        }
    }

    private func temporaryShelfFiles(for batch: CaptureShelfBatch, prefix: String) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let timestamp = Self.timestamp()
        var urls = try batch.images.enumerated().compactMap { index, image -> URL? in
            guard let pngData = Self.pngData(from: image) else { return nil }
            let filename = "desk-agent-shelf-\(timestamp)-\(String(format: "%02d", index + 1)).png"
            let url = folder.appendingPathComponent(filename)
            try pngData.write(to: url, options: .atomic)
            return url
        }
        urls.append(contentsOf: batch.clips)
        return urls
    }

    func prependShelfBatch(_ batch: CaptureShelfBatch) {
        shelfBatches.insert(batch, at: 0)
        trimShelfBatchesIfNeeded()
    }

    private func trimShelfBatchesIfNeeded() {
        guard shelfBatches.count > Self.maxShelfBatches else { return }
        let overflow = shelfBatches.count - Self.maxShelfBatches
        shelfBatches.removeLast(overflow)
        MarkShotLog.write("shelf trimmed overflow=\(overflow) max=\(Self.maxShelfBatches)")
    }

    private func ensureShelfWindow() -> NotchShelfWindowController {
        if let shelfWindowController {
            return shelfWindowController
        }
        let controller = NotchShelfWindowController(state: self)
        shelfWindowController = controller
        return controller
    }

    private func restackCaptureThumbnails() {
        for (index, controller) in captureThumbnailControllers.enumerated() {
            controller.move(toStackIndex: index)
        }
    }

    func saveAllCaptureThumbnails() {
        guard !captureThumbnailControllers.isEmpty else {
            statusMessage = "No capture thumbnails to save."
            showToolbar()
            return
        }

        let panel = NSOpenPanel()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.defaultScreenshotsDirectory()
        panel.prompt = "Save All"
        panel.message = "Choose a folder for the captured screenshots."

        guard panel.runModal() == .OK, let folder = panel.url else {
            statusMessage = "Save all cancelled."
            return
        }

        let timestamp = Self.timestamp()
        var savedCount = 0

        for (index, controller) in captureThumbnailControllers.enumerated() {
            guard let pngData = Self.pngData(from: controller.image) else { continue }
            let filename = "markshot-\(timestamp)-\(String(format: "%02d", index + 1)).png"
            let url = folder.appendingPathComponent(filename)
            do {
                try pngData.write(to: url, options: .atomic)
                savedCount += 1
            } catch {
                statusMessage = "Save all failed: \(error.localizedDescription)"
                showToolbar()
                return
            }
        }

        statusMessage = "Saved \(savedCount) screenshot\(savedCount == 1 ? "" : "s") to \(folder.path)."
    }

    // MARK: - Record Clip

    func recordClip() {
        isRecordingClip = true
        statusMessage = "Starting screen recording..."
        hideToolbar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ScreenshotService.recordClip { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRecordingClip = false
                    switch result {
                    case .success(let url):
                        self.lastRecordedClipURL = url
                        self.prependShelfBatch(CaptureShelfBatch(clips: [url], createdAt: Date()))
                        self.statusMessage = "Clip saved to the notch shelf."
                        self.ensureShelfWindow().showExpanded()
                    case .failure(let error):
                        self.statusMessage = "Recording stopped: \(error.localizedDescription)"
                        self.showToolbar()
                    }
                }
            }
        }
    }

    func revealLastClipInFinder() {
        guard let lastRecordedClipURL else {
            statusMessage = "No recorded clip yet."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordedClipURL])
    }

    func openVideoFrameLab() {
        statusMessage = "Opening VideoFrame Lab..."
        Task {
            do {
                try await VideoFrameLabService.shared.ensureRunning()
                await MainActor.run {
                    self.isVideoFrameLabActive = true
                    self.statusMessage = "VideoFrame Lab opened."
                    NSWorkspace.shared.open(VideoFrameLabService.shared.baseURL)
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.showToolbar()
                }
            }
        }
    }

    func stopVideoFrameLab() {
        VideoFrameLabService.shared.stop()
        isVideoFrameLabActive = false
        statusMessage = "VideoFrame Lab stopped."
    }

    func sendLastClipToVideoFrameLab() {
        guard let lastRecordedClipURL else {
            statusMessage = "No recorded clip to send yet."
            return
        }

        isSendingClipToVideoFrame = true
        statusMessage = "Starting VideoFrame Lab and sending clip..."

        Task {
            do {
                let result = try await VideoFrameLabService.shared.importClip(lastRecordedClipURL)
                await MainActor.run {
                    self.isSendingClipToVideoFrame = false
                    self.isVideoFrameLabActive = true
                    self.statusMessage = "Sent clip to VideoFrame Lab job \(result.jobId)."
                    NSWorkspace.shared.open(result.url)
                    self.hideAfterExport()
                }
            } catch {
                await MainActor.run {
                    self.isSendingClipToVideoFrame = false
                    self.statusMessage = error.localizedDescription
                    self.showToolbar()
                }
            }
        }
    }

    // MARK: - Delay Capture

    func captureWithDelay(seconds: Int, mode: ScreenshotMode) {
        countdownCapture(remaining: seconds, mode: mode)
    }

    private func countdownCapture(remaining: Int, mode: ScreenshotMode) {
        guard remaining > 0 else {
            capture(mode: mode)
            return
        }
        statusMessage = "Capturing in \(remaining)s..."
        let next = remaining - 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.countdownCapture(remaining: next, mode: mode)
        }
    }

    func copyRenderedImageToClipboard() {
        guard let pngData = renderedPNGData() else {
            statusMessage = "Nothing to copy yet."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let image = renderedImage() {
            pasteboard.writeObjects([image])
        }
        statusMessage = "Copied annotated PNG to clipboard."
        hideAfterExport()
    }

    private func copyImageToClipboard(_ image: NSImage) {
        guard let pngData = Self.pngData(from: image) else {
            statusMessage = "Could not copy screenshot."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        pasteboard.writeObjects([image])
        statusMessage = "Copied screenshot to clipboard."
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func saveRenderedImage() {
        guard let pngData = renderedPNGData() else {
            statusMessage = "Nothing to save yet."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = Self.defaultScreenshotsDirectory()
        panel.nameFieldStringValue = "markshot-\(Self.timestamp()).png"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try pngData.write(to: url, options: .atomic)
                statusMessage = "Saved PNG to \(url.path)."
                hideAfterExport()
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Save cancelled."
        }
    }

    func dragItemProvider() -> NSItemProvider {
        guard let pngData = renderedPNGData() else {
            return NSItemProvider(object: "No screenshot captured yet." as NSString)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markshot-drag-\(UUID().uuidString).png")

        do {
            try pngData.write(to: url, options: .atomic)
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
            statusMessage = "Dragging annotated PNG."
            return provider
        } catch {
            return NSItemProvider(object: "Desk Agent export failed: \(error.localizedDescription)" as NSString)
        }
    }

    func renderedPNGData() -> Data? {
        guard let image = renderedImage(),
              let pngData = Self.pngData(from: image)
        else { return nil }

        return pngData
    }

    func renderedImage() -> NSImage? {
        guard let baseImage else { return nil }

        let imageSize = baseImage.pixelSize
        let output = NSImage(size: imageSize)
        output.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        baseImage.draw(in: NSRect(origin: .zero, size: imageSize))

        AnnotationRenderer.draw(
            annotations: annotations,
            in: NSRect(origin: .zero, size: imageSize),
            imageSize: imageSize
        )

        output.unlockFocus()
        return output
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func defaultScreenshotsDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func obsidianInboxDirectory() -> URL {
        if let configured = ProcessInfo.processInfo.environment["DESK_AGENT_OBSIDIAN_INBOX"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DeskAgent/inbox", isDirectory: true)
    }

    private static func obsidianQuickNoteEntry(_ note: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = formatter.string(from: Date())
        return "## \(timestamp)\n\n\(note)\n\n"
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func boardImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedRed: 0.965, green: 0.966, blue: 0.95, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor.black.withAlphaComponent(0.16).setFill()
        let spacing: CGFloat = 24
        let dotSize: CGFloat = 2.4
        var x: CGFloat = spacing
        while x < size.width {
            var y: CGFloat = spacing
            while y < size.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
                y += spacing
            }
            x += spacing
        }

        image.unlockFocus()
        return image
    }

    private func hideAfterExport() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.hideToolbar()
        }
    }

    func showToolbar() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.forEach { window in
            guard window.identifier == mainWindowIdentifier else { return }
            window.orderFrontRegardless()
        }
    }

    func hideToolbar() {
        NSApp.windows.forEach { window in
            guard window.identifier == mainWindowIdentifier else { return }
            window.orderOut(nil)
        }
    }

    private func hideForCapture() {
        NSApp.hide(nil)
    }
}

private extension NSImage {
    var pixelSize: NSSize {
        if let rep = representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}
