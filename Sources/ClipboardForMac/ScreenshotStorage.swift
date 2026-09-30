import Foundation

enum ScreenshotStorage {
    static func destinationDirectory() -> URL? {
        let preference = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return directory(for: preference, desktop: desktop)
    }

    static func directory(for raw: String?, desktop: URL?) -> URL? {
        if let raw, !raw.isEmpty {
            if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { return url }
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        return desktop
    }

    static func newCaptureURL(in directory: URL, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = String(UUID().uuidString.prefix(8))
        return directory.appendingPathComponent("ClipboardForMac \(formatter.string(from: date)) \(suffix).png")
    }
}
