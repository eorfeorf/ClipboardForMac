import Combine
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

enum ScreenshotSaveLocation: String {
    case system
    case desktop
    case custom
}

@MainActor
final class ScreenshotPreferences: ObservableObject {
    @Published private(set) var location: ScreenshotSaveLocation
    @Published private(set) var customDirectory: URL?

    private let defaults: UserDefaults
    private let locationKey = "screenshotSaveLocation"
    private let customDirectoryKey = "screenshotCustomDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedPath = defaults.string(forKey: customDirectoryKey)
        let savedDirectory = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        customDirectory = savedDirectory
        let savedLocation = ScreenshotSaveLocation(rawValue: defaults.string(forKey: locationKey) ?? "") ?? .system
        location = savedLocation == .custom && savedDirectory == nil ? .system : savedLocation
    }

    var destinationDirectory: URL? {
        switch location {
        case .system: ScreenshotStorage.destinationDirectory()
        case .desktop: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .custom: customDirectory
        }
    }

    func use(_ selected: ScreenshotSaveLocation) {
        guard selected != .custom || customDirectory != nil else { return }
        location = selected
        defaults.set(selected.rawValue, forKey: locationKey)
    }

    func useCustomDirectory(_ url: URL) {
        customDirectory = url.standardizedFileURL
        defaults.set(customDirectory?.path, forKey: customDirectoryKey)
        use(.custom)
    }
}
