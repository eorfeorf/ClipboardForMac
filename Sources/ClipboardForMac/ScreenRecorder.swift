import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class ScreenRecorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    var onRecordingChanged: ((Bool) -> Void)?
    var onSaved: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var writer: MovieWriter?
    private var outputURL: URL?
    private var isStopping = false
    private var pickerIsOpen = false

    var isRecording: Bool { stream != nil && !isStopping }
    var isFinishing: Bool { isStopping }

    func pick(_ mode: CaptureMode) {
        guard stream == nil, !isStopping, !pickerIsOpen else { return }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = mode == .window ? .singleWindow : .singleDisplay
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        pickerIsOpen = true
        picker.present(using: mode == .window ? .window : .display)
    }

    func record(screen: NSScreen, region: CGRect) {
        guard stream == nil, !isStopping else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    throw CaptureError.displayUnavailable
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let source = CGRect(x: region.minX,
                                    y: screen.frame.height - region.maxY,
                                    width: region.width, height: region.height)
                try await start(filter: filter, sourceRect: source)
            } catch {
                onError?("画面収録を開始できませんでした。画面収録の許可を確認してください。")
            }
        }
    }

    func record(filter: SCContentFilter) {
        guard stream == nil, !isStopping else { return }
        Task {
            do { try await start(filter: filter, sourceRect: nil) }
            catch { onError?("画面収録を開始できませんでした。画面収録の許可を確認してください。") }
        }
    }

    func record(windowID: CGWindowID) {
        guard stream == nil, !isStopping else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureError.displayUnavailable
                }
                try await start(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil)
            } catch {
                onError?("ウィンドウの録画を開始できませんでした。")
            }
        }
    }

    func stop() {
        guard let stream, !isStopping else { return }
        isStopping = true
        onRecordingChanged?(false)
        Task {
            try? await stream.stopCapture()
            self.stream = nil
            let writer = self.writer
            self.writer = nil
            writer?.finish { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isStopping = false
                    if success, let url = self.outputURL {
                        self.onSaved?(url)
                    } else {
                        if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                        self.onError?("動画を保存できませんでした。")
                    }
                    self.outputURL = nil
                }
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            closePicker(picker)
            record(filter: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in closePicker(picker) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            closePicker(SCContentSharingPicker.shared)
            onError?("撮影する対象を選べませんでした。")
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping else { return }
            self.onError?("画面収録が中断されました。")
            self.stop()
        }
    }

    private func closePicker(_ picker: SCContentSharingPicker) {
        picker.remove(self)
        picker.isActive = false
        pickerIsOpen = false
    }

    private func start(filter: SCContentFilter, sourceRect: CGRect?) async throws {
        guard stream == nil, !isStopping else { return }
        let rect = sourceRect ?? filter.contentRect
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let naturalWidth = max(Int(rect.width * scale), 2)
        let naturalHeight = max(Int(rect.height * scale), 2)
        let factor = min(1, min(3840.0 / Double(naturalWidth), 2160.0 / Double(naturalHeight)))
        let width = max(2, Int(Double(naturalWidth) * factor) & ~1)
        let height = max(2, Int(Double(naturalHeight) * factor) & ~1)

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardForMac", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = movies.appendingPathComponent("Recording_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mov")

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        if let sourceRect { configuration.sourceRect = sourceRect }

        let movieWriter = try MovieWriter(url: url, width: width, height: height)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try captureStream.addStreamOutput(movieWriter, type: .screen, sampleHandlerQueue: movieWriter.queue)
        do {
            try await captureStream.startCapture()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        outputURL = url
        writer = movieWriter
        stream = captureStream
        isStopping = false
        onRecordingChanged?(true)
    }

    private enum CaptureError: Error { case displayUnavailable }
}

final class MovieWriter: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "ClipboardForMac.movieWriter")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var finished = false

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(16_000_000, width * height * 4)]
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        append(sampleBuffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !finished, sampleBuffer.isValid else { return }
        if let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachmentArray.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData { _ = input.append(sampleBuffer) }
    }

    func finish(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            self.finished = true
            guard self.started, self.writer.status == .writing else {
                self.writer.cancelWriting()
                completion(false)
                return
            }
            self.input.markAsFinished()
            self.writer.finishWriting { completion(self.writer.status == .completed) }
        }
    }
}
