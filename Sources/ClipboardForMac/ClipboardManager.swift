import AppKit
import ApplicationServices
import CryptoKit
import ServiceManagement

@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var query = "" {
        didSet { selectedID = filteredEntries.first?.id }
    }
    @Published var selectedID: UUID?
    @Published private(set) var canAutoPaste = AXIsProcessTrusted()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?

    var onSelect: (() -> Void)?
    var onScreenshotRequest: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let maxUnpinnedEntries = 25
    private let maxImageBytes = 24 * 1024 * 1024
    private let maxTextBytes = 4 * 1024 * 1024
    private var observedChangeCount: Int
    private var timer: Timer?
    private let storageDirectory: URL

    init(pasteboard: NSPasteboard = .general, storageDirectory: URL? = nil) {
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageDirectory = storageDirectory ?? support.appendingPathComponent("ClipboardForMac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.storageDirectory.path)
        load()
    }

    var filteredEntries: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(needle)
                || (entry.fileURLs ?? []).contains { URL(string: $0)?.lastPathComponent.localizedCaseInsensitiveContains(needle) == true }
        }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        captureCurrentClipboard()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureCurrentClipboard() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        canAutoPaste = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshPermissions()
        } catch {
            errorMessage = "ログイン時の起動を変更できませんでした。アプリを「アプリケーション」フォルダーへ移動してから再試行してください。"
            refreshPermissions()
        }
    }

    func moveSelection(by offset: Int) {
        let visible = filteredEntries
        guard !visible.isEmpty else { selectedID = nil; return }
        let current = visible.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : 0)
        let next = max(0, min(visible.count - 1, current + offset))
        selectedID = visible[next].id
    }

    func selectCurrent() {
        guard let entry = filteredEntries.first(where: { $0.id == selectedID }) ?? filteredEntries.first else { return }
        select(entry)
    }

    func select(_ entry: ClipboardEntry) {
        let success: Bool
        switch entry.kind {
        case .text:
            let item = NSPasteboardItem()
            item.setString(entry.text ?? "", forType: .string)
            if let filename = entry.richTextFilename,
               let data = try? Data(contentsOf: storageDirectory.appendingPathComponent(filename)),
               let representations = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] {
                for (type, content) in representations {
                    item.setData(content, forType: NSPasteboard.PasteboardType(type))
                }
            }
            pasteboard.clearContents()
            success = pasteboard.writeObjects([item])
        case .image:
            guard let filename = entry.imageFilename,
                  let image = NSImage(contentsOf: storageDirectory.appendingPathComponent(filename)) else {
                errorMessage = "この画像を読み込めませんでした。"
                return
            }
            pasteboard.clearContents()
            success = pasteboard.writeObjects([image])
        case .files:
            let urls = (entry.fileURLs ?? []).compactMap(URL.init(string:)).filter(\.isFileURL)
            guard !urls.isEmpty else {
                errorMessage = "このファイルを読み込めませんでした。"
                return
            }
            pasteboard.clearContents()
            success = pasteboard.writeObjects(urls as [NSURL])
        }
        observedChangeCount = pasteboard.changeCount
        guard success else {
            errorMessage = "この項目をコピーできませんでした。"
            return
        }
        onSelect?()
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        trimHistory()
        save()
    }

    func delete(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        if selectedID == entry.id { selectedID = filteredEntries.first?.id }
        cleanUnusedAssets()
        save()
    }

    func clearUnpinned() {
        entries.removeAll { !$0.isPinned }
        selectedID = filteredEntries.first?.id
        cleanUnusedAssets()
        save()
    }

    func image(for entry: ClipboardEntry) -> NSImage? {
        guard let filename = entry.imageFilename else { return nil }
        return NSImage(contentsOf: storageDirectory.appendingPathComponent(filename))
    }

    func captureCurrentClipboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        observedChangeCount = changeCount

        let types = pasteboard.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType")
            || types.contains("org.nspasteboard.TransientType")
            || types.contains("org.nspasteboard.AutoGeneratedType") {
            return
        }

        if let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !files.isEmpty {
            let values = files.map(\.absoluteString)
            addEntry(kind: .files, payload: values.joined(separator: "\n"), fileURLs: values)
            return
        }

        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains(NSPasteboard.PasteboardType.png.rawValue),
           let image = NSImage(pasteboard: pasteboard),
           let png = Self.pngData(from: image),
           png.count <= maxImageBytes {
            addImage(png)
            return
        }

        if let value = pasteboard.string(forType: .string),
           !value.isEmpty,
           value.utf8.count <= maxTextBytes {
            var richData: [String: Data] = [:]
            for type in [NSPasteboard.PasteboardType.rtf, .html] {
                if let data = pasteboard.data(forType: type), data.count <= maxTextBytes {
                    richData[type.rawValue] = data
                }
            }
            addEntry(kind: .text, payload: value, text: value, richData: richData)
        }
    }

    func importScreenshot(at url: URL) async -> Bool {
        let png = await Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url) else { return nil as Data? }
            return Self.pngData(from: image)
        }.value
        guard let png,
              png.count <= maxImageBytes else { return false }
        return addImage(png)
    }

    func addRecordedVideo(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "録画ファイルを読み込めませんでした。"
            return
        }
        addEntry(kind: .files, payload: url.absoluteString, fileURLs: [url.absoluteString])
    }

    @discardableResult
    func useSavedScreenshot(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "保存したスクリーンショットを読み込めませんでした。"
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            errorMessage = "スクリーンショットをクリップボードにコピーできませんでした。"
            return false
        }
        captureCurrentClipboard()
        return true
    }

    nonisolated private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    @discardableResult
    private func addImage(_ data: Data) -> Bool {
        let fingerprint = digest(data)
        if let existing = entries.first(where: { $0.fingerprint == fingerprint && $0.kind == .image }) {
            bringToFront(existing)
            return true
        }
        let filename = "\(UUID().uuidString).png"
        do {
            try data.write(to: storageDirectory.appendingPathComponent(filename), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageDirectory.appendingPathComponent(filename).path
            )
            let entry = ClipboardEntry(id: UUID(), kind: .image, fingerprint: fingerprint,
                                       createdAt: Date(), isPinned: false, text: nil,
                                       imageFilename: filename, fileURLs: nil)
            entries.insert(entry, at: 0)
            selectedID = entry.id
            trimHistory()
            save()
            return true
        } catch {
            errorMessage = "画像を保存できませんでした。"
            return false
        }
    }

    private func addEntry(kind: ClipboardKind, payload: String, text: String? = nil,
                          fileURLs: [String]? = nil, richData: [String: Data] = [:]) {
        var fingerprintData = Data(payload.utf8)
        for type in richData.keys.sorted() {
            fingerprintData.append(Data(type.utf8))
            fingerprintData.append(richData[type] ?? Data())
        }
        let fingerprint = digest(fingerprintData)
        if let existing = entries.first(where: { $0.fingerprint == fingerprint && $0.kind == kind }) {
            bringToFront(existing)
            return
        }
        var richTextFilename: String?
        if !richData.isEmpty,
           let data = try? PropertyListSerialization.data(fromPropertyList: richData, format: .binary, options: 0) {
            let filename = "\(UUID().uuidString).plist"
            let url = storageDirectory.appendingPathComponent(filename)
            if (try? data.write(to: url, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                richTextFilename = filename
            }
        }
        let entry = ClipboardEntry(id: UUID(), kind: kind, fingerprint: fingerprint,
                                   createdAt: Date(), isPinned: false, text: text,
                                   imageFilename: nil, fileURLs: fileURLs, richTextFilename: richTextFilename)
        entries.insert(entry, at: 0)
        selectedID = entry.id
        trimHistory()
        save()
    }

    private func bringToFront(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        var updated = entry
        updated.createdAt = Date()
        entries.insert(updated, at: 0)
        selectedID = updated.id
        save()
    }

    private func trimHistory() {
        var unpinned = 0
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            unpinned += 1
            return unpinned <= maxUnpinnedEntries
        }
        cleanUnusedAssets()
    }

    private func cleanUnusedAssets() {
        let keep = Set(entries.compactMap(\.imageFilename) + entries.compactMap(\.richTextFilename))
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["png", "plist"].contains(file.pathExtension)
            && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
            && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        let url = storageDirectory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        entries = saved.filter { entry in
            entry.kind != .image || (entry.imageFilename.map { FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent($0).path) } ?? false)
        }
        trimHistory()
        selectedID = entries.first?.id
    }

    private func save() {
        let url = storageDirectory.appendingPathComponent("history.json")
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            errorMessage = "履歴を保存できませんでした。"
        }
    }
}
