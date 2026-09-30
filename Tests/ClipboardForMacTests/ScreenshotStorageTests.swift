import Foundation
import XCTest
@testable import ClipboardForMac

@MainActor
final class ScreenshotStorageTests: XCTestCase {
    func testConfiguredScreenshotDirectoryAndDesktopFallback() {
        let desktop = URL(fileURLWithPath: "/tmp/Desktop", isDirectory: true)
        let custom = URL(fileURLWithPath: "/tmp/Captures", isDirectory: true)

        XCTAssertEqual(ScreenshotStorage.directory(for: custom.path, desktop: desktop), custom)
        XCTAssertEqual(ScreenshotStorage.directory(for: custom.absoluteString, desktop: desktop), custom)
        XCTAssertEqual(ScreenshotStorage.directory(for: nil, desktop: desktop), desktop)
        XCTAssertEqual(ScreenshotStorage.directory(for: "Clipboard", desktop: desktop), desktop)
    }

    func testCaptureFilenameIsUnique() {
        let directory = URL(fileURLWithPath: "/tmp/Captures", isDirectory: true)
        let date = Date(timeIntervalSince1970: 0)
        let first = ScreenshotStorage.newCaptureURL(in: directory, at: date)
        let second = ScreenshotStorage.newCaptureURL(in: directory, at: date)

        XCTAssertEqual(first.deletingLastPathComponent(), directory)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("ClipboardForMac "))
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertNotEqual(first, second)
    }

    func testSaveLocationChoicePersists() throws {
        let suiteName = "ClipboardForMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = URL(fileURLWithPath: "/tmp/My Captures", isDirectory: true)

        let preferences = ScreenshotPreferences(defaults: defaults)
        XCTAssertEqual(preferences.location, .system)

        preferences.use(.desktop)
        XCTAssertEqual(ScreenshotPreferences(defaults: defaults).location, .desktop)

        preferences.useCustomDirectory(custom)
        let reloaded = ScreenshotPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.location, .custom)
        XCTAssertEqual(reloaded.destinationDirectory, custom)

        reloaded.use(.system)
        XCTAssertEqual(ScreenshotPreferences(defaults: defaults).location, .system)
    }
}
