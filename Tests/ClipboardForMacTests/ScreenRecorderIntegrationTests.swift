import AppKit
import AVFoundation
import CoreGraphics
import XCTest
@testable import ClipboardForMac

@MainActor
final class ScreenRecorderIntegrationTests: XCTestCase {
    func testRecording() async throws {
        try await verifyRecording { recorder, screen, window in
            if ProcessInfo.processInfo.environment["CLIPBOARDFORMAC_CAPTURE_SMOKE_TEST"] == "region" {
                let region = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                recorder.record(screen: screen, region: region)
            } else {
                recorder.record(windowID: CGWindowID(window.windowNumber))
            }
            return true
        }
    }

    private func verifyRecording(
        start: @escaping (ScreenRecorder, NSScreen, NSWindow) async throws -> Bool
    ) async throws {
        guard ProcessInfo.processInfo.environment["CLIPBOARDFORMAC_CAPTURE_SMOKE_TEST"] != nil else {
            throw XCTSkip("Run explicitly on a Mac with screen recording access")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen recording access is unavailable")
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: screen.frame.midX - 80, y: screen.frame.midY - 60,
                                                  width: 160, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.systemBlue.cgColor
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let recorder = ScreenRecorder()
        let started = expectation(description: "recording started")
        let saved = expectation(description: "recording saved")
        var movieURL: URL?
        var recorderError: String?
        var startedFulfilled = false
        var savedFulfilled = false
        recorder.onRecordingChanged = { active in
            if active {
                startedFulfilled = true
                started.fulfill()
            }
        }
        recorder.onSaved = { url in
            movieURL = url
            savedFulfilled = true
            saved.fulfill()
        }
        recorder.onError = { message in
            recorderError = message
            if !startedFulfilled { startedFulfilled = true; started.fulfill() }
            if !savedFulfilled { savedFulfilled = true; saved.fulfill() }
        }
        guard try await start(recorder, screen, window) else { return }
        await fulfillment(of: [started], timeout: 10)
        if let recorderError { XCTFail(recorderError); return }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        recorder.stop()
        await fulfillment(of: [saved], timeout: 15)
        if let recorderError { XCTFail(recorderError); return }
        let url = try XCTUnwrap(movieURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan((try Data(contentsOf: url)).count, 100)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }
}
