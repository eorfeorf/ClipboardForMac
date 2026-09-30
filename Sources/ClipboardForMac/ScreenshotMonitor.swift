import CoreServices
import Foundation

private let screenshotEventCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info else { return }
    let monitor = Unmanaged<ScreenshotMonitor>.fromOpaque(info).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let urls = (0..<count).map { URL(fileURLWithPath: String(cString: paths[$0])) }
    Task { @MainActor in monitor.receiveEvents(at: urls) }
}

@MainActor
final class ScreenshotMonitor {
    private let directoryProvider: @MainActor () -> URL?
    private let nameProvider: @MainActor () -> [String]
    private let onScreenshot: @MainActor (URL) async -> Bool
    private let onAccessError: @MainActor (URL) -> Void
    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "pdf"]
    private var timer: Timer?
    private var stream: FSEventStreamRef?
    private var watchedDirectory: URL?
    private var pendingSizes: [URL: Int] = [:]
    private var failedAttempts: [URL: Int] = [:]
    private var importingFiles: Set<URL> = []
    private var importedFiles: Set<URL> = []
    private var reportedAccessError: URL?

    init(
        directoryProvider: @escaping @MainActor () -> URL? = ScreenshotStorage.destinationDirectory,
        nameProvider: @escaping @MainActor () -> [String] = ScreenshotMonitor.screenshotNames,
        onAccessError: @escaping @MainActor (URL) -> Void = { _ in },
        onScreenshot: @escaping @MainActor (URL) async -> Bool
    ) {
        self.directoryProvider = directoryProvider
        self.nameProvider = nameProvider
        self.onAccessError = onAccessError
        self.onScreenshot = onScreenshot
    }

    func start() {
        guard timer == nil else { return }
        updateWatch()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWatch()
                await self?.processPending()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeStream()
        watchedDirectory = nil
        pendingSizes.removeAll()
        failedAttempts.removeAll()
        importingFiles.removeAll()
        importedFiles.removeAll()
    }

    // The event stream reports only changes after it starts, so existing files
    // never enter the history when the app launches.
    private func updateWatch() {
        guard let directory = directoryProvider()?.standardizedFileURL else { return }
        guard directory != watchedDirectory else { return }
        closeStream()
        pendingSizes.removeAll()
        failedAttempts.removeAll()
        importingFiles.removeAll()
        importedFiles.removeAll()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            screenshotEventCallback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            reportAccessError(for: directory)
            return
        }
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            reportAccessError(for: directory)
            return
        }
        stream = newStream
        watchedDirectory = directory
        reportedAccessError = nil
    }

    private func closeStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func receiveEvents(at urls: [URL]) {
        guard let watchedDirectory else { return }
        let names = nameProvider()
        for url in urls {
            let file = url.standardizedFileURL
            guard file.deletingLastPathComponent() == watchedDirectory,
                  isScreenshot(file, names: names),
                  !importedFiles.contains(file),
                  !importingFiles.contains(file) else { continue }
            if pendingSizes[file] == nil { pendingSizes[file] = 0 }
        }
    }

    func processPending() async {
        for (file, previousSize) in pendingSizes {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0 else { continue }

            if previousSize != size {
                pendingSizes[file] = size
                continue
            }

            if !importingFiles.isEmpty { continue }
            pendingSizes.removeValue(forKey: file)
            importingFiles.insert(file)
            let accessCheck = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) }
                catch { return }
                guard let self, self.importingFiles.contains(file),
                      let watchedDirectory = self.watchedDirectory else { return }
                self.reportAccessError(for: watchedDirectory)
            }
            let success = await onScreenshot(file)
            accessCheck.cancel()
            importingFiles.remove(file)
            guard timer != nil else { continue }
            if success {
                importedFiles.insert(file)
                failedAttempts.removeValue(forKey: file)
            } else {
                let attempts = (failedAttempts[file] ?? 0) + 1
                failedAttempts[file] = attempts
                if attempts >= 3 {
                    failedAttempts.removeValue(forKey: file)
                } else {
                    pendingSizes[file] = size
                }
            }
        }
    }

    private func reportAccessError(for directory: URL) {
        if reportedAccessError != directory {
            reportedAccessError = directory
            onAccessError(directory)
        }
    }

    private func isScreenshot(_ url: URL, names: [String]) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let basename = url.deletingPathExtension().lastPathComponent
        return names.contains { name in
            let prefix = name + " "
            guard basename.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil else { return false }
            return basename.dropFirst(prefix.count).first?.isNumber == true
        }
    }

    private static func screenshotNames() -> [String] {
        var names = ["スクリーンショット", "Screenshot", "Screen Shot"]
        if let custom = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String,
           !custom.isEmpty {
            names.append(custom)
        }
        return names
    }
}
