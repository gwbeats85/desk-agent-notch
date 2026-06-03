import XCTest
@testable import MarkShot

final class MacFileOperationServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-agent-fileops-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCreateFolderCreatesNamedFolder() throws {
        let created = try MacFileOperationService.createFolder(in: tempRoot, named: "New Folder")

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCreateEmptyFileCreatesNamedFileWithoutOverwrite() throws {
        let created = try MacFileOperationService.createEmptyFile(in: tempRoot, named: "note.md")

        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertThrowsError(try MacFileOperationService.createEmptyFile(in: tempRoot, named: "note.md"))
    }

    func testRenameMovesItemToNewNameInSameFolder() throws {
        let original = tempRoot.appendingPathComponent("old.txt")
        try Data("hello".utf8).write(to: original)

        let renamed = try MacFileOperationService.rename(original, to: "new.txt")

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: renamed), "hello")
    }

    func testInvalidNamesAreRejected() throws {
        XCTAssertThrowsError(try MacFileOperationService.validateItemName(""))
        XCTAssertThrowsError(try MacFileOperationService.validateItemName("../bad"))
        XCTAssertThrowsError(try MacFileOperationService.validateItemName("bad/name"))
    }

    func testArchiveCreatesZipForSelectedItems() throws {
        let first = tempRoot.appendingPathComponent("first.txt")
        let second = tempRoot.appendingPathComponent("second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let archive = try MacFileOperationService.archive([first, second], archiveName: "Bundle", destinationFolder: tempRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(archive.pathExtension, "zip")
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 0)
    }

    func testCopyItemsCreatesUniqueCopiesInDestinationFolder() throws {
        let source = tempRoot.appendingPathComponent("clip.txt")
        let destination = tempRoot.appendingPathComponent("destination", isDirectory: true)
        try Data("clip".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("clip.txt"))

        let copied = try MacFileOperationService.copyItems([source], to: destination)

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied[0].lastPathComponent, "clip 2.txt")
        XCTAssertEqual(try String(contentsOf: copied[0]), "clip")
    }

    func testMoveItemsMovesIntoDestinationWithoutOverwrite() throws {
        let source = tempRoot.appendingPathComponent("move-me.txt")
        let destination = tempRoot.appendingPathComponent("destination", isDirectory: true)
        try Data("move".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let moved = try MacFileOperationService.moveItems([source], to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: moved[0]), "move")
    }
}
