import AppKit
import XCTest
@testable import ClipboardForMac

@MainActor
final class ClipboardManagerTests: XCTestCase {
    private func makeFixture() throws -> (ClipboardManager, NSPasteboard, URL) {
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardForMacTests.\(UUID().uuidString)"))
        board.clearContents()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = ClipboardManager(pasteboard: board, storageDirectory: directory)
        return (manager, board, directory)
    }

    func testPinnedEntrySurvivesHistoryLimitAndReload() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        board.clearContents()
        board.setString("固定する内容", forType: .string)
        manager.captureCurrentClipboard()
        let pinned = try XCTUnwrap(manager.entries.first)
        manager.togglePin(pinned)

        for index in 0..<30 {
            board.clearContents()
            board.setString("項目 \(index)", forType: .string)
            manager.captureCurrentClipboard()
        }

        XCTAssertEqual(manager.entries.count, 26)
        XCTAssertTrue(manager.entries.contains { $0.id == pinned.id && $0.isPinned })

        manager.clearUnpinned()
        XCTAssertEqual(manager.entries.map(\.id), [pinned.id])
        let reloaded = ClipboardManager(pasteboard: board, storageDirectory: directory)
        XCTAssertEqual(reloaded.entries.map(\.id), [pinned.id])
    }

    func testConcealedContentIsNotRecorded() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("secret", forType: .string)
        manager.captureCurrentClipboard()

        XCTAssertTrue(manager.entries.isEmpty)
    }

    func testFileRoundTrip() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.txt")
        try Data("test".utf8).write(to: file)

        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        manager.captureCurrentClipboard()
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(entry.kind, .files)

        manager.select(entry)
        let restored = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(restored?.first, file)
    }

    func testRecordedVideoAppearsInHistoryAndCanBeCopied() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Recording.mov")
        try Data("movie".utf8).write(to: movie)

        manager.addRecordedVideo(at: movie)
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(entry.title, "Recording.mov")
        let reloaded = ClipboardManager(pasteboard: board, storageDirectory: directory)
        let restoredEntry = try XCTUnwrap(reloaded.entries.first)
        reloaded.select(restoredEntry)
        let copied = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(copied?.first, movie)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    }

    func testImageRoundTrip() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()

        board.clearContents()
        XCTAssertTrue(board.writeObjects([image]))
        manager.captureCurrentClipboard()
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertNotNil(manager.image(for: entry))

        manager.select(entry)
        XCTAssertNotNil(NSImage(pasteboard: board))
    }

    func testSavedScreenshotIsCopiedAndRecordedWithoutDeletingTheOriginal() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let screenshot = ScreenshotStorage.newCaptureURL(in: directory)
        try png.write(to: screenshot)

        manager.useSavedScreenshot(at: screenshot)

        XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertEqual(manager.entries.first?.kind, .image)
        let historyCopy = directory.appendingPathComponent(try XCTUnwrap(manager.entries.first?.imageFilename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyCopy.path))
        manager.clearUnpinned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
    }

    func testRichTextRoundTrip() throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = Data("<b>bold</b>".utf8)
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(html, forType: .html)

        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        manager.captureCurrentClipboard()
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(entry.kind, .text)

        manager.select(entry)
        XCTAssertEqual(board.string(forType: .string), "bold")
        XCTAssertEqual(board.data(forType: .html), html)
    }

    func testNewScreenshotsAreRecordedWithoutChangingClipboard() async throws {
        let (manager, board, directory) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshots = directory.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)

        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let old = screenshots.appendingPathComponent("スクリーンショット 2026-09-30 12.00.00.png")
        try png.write(to: old)
        var importedURLs: [URL] = []
        let monitor = ScreenshotMonitor(
            directoryProvider: { screenshots },
            nameProvider: { ["スクリーンショット"] },
            onScreenshot: { url in
                importedURLs.append(url)
                return await manager.importScreenshot(at: url)
            }
        )
        monitor.start()
        defer { monitor.stop() }

        let fresh = screenshots.appendingPathComponent("スクリーンショット 2026-09-30 12.00.01.png")
        let unrelated = screenshots.appendingPathComponent("photo.png")
        try png.write(to: fresh)
        try png.write(to: unrelated)
        let clipboardChangeCount = board.changeCount

        monitor.receiveEvents(at: [fresh, unrelated])
        await monitor.processPending() // Wait until the new file has a stable size.
        XCTAssertTrue(manager.entries.isEmpty)
        await monitor.processPending()

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.kind, .image)
        XCTAssertEqual(board.changeCount, clipboardChangeCount)

        let eventFile = screenshots.appendingPathComponent("スクリーンショット 2026-09-30 12.00.02.png")
        try png.write(to: eventFile)
        for _ in 0..<50 {
            if importedURLs.contains(eventFile) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(importedURLs.contains(eventFile), "The file system event should import the new screenshot")
        XCTAssertEqual(board.changeCount, clipboardChangeCount)
    }
}
