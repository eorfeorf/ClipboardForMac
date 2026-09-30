import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import ClipboardForMac

final class MovieWriterTests: XCTestCase {
    func testMovieWriterCreatesPlayableFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MovieWriter(url: url, width: 64, height: 64)

        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                           kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                           &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                     imageBuffer: buffer,
                                                                     formatDescriptionOut: &format), noErr)
        let description = try XCTUnwrap(format)
        for frame in 0..<3 {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                     imageBuffer: buffer,
                                                                     formatDescription: description,
                                                                     sampleTiming: &timing,
                                                                     sampleBufferOut: &sample), noErr)
            let frameBuffer = try XCTUnwrap(sample)
            writer.queue.sync { writer.append(frameBuffer) }
        }

        let completed = expectation(description: "movie finished")
        writer.finish { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertGreaterThan((try Data(contentsOf: url)).count, 100)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }
}
