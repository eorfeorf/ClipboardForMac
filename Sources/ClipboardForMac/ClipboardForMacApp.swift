import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@main
struct ClipboardForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private let hotKeyHandler: EventHandlerUPP = { _, event, pointer in
    guard let pointer, let event else { return noErr }
    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == OSType(0x43464D43) else { return status }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
    Task { @MainActor in
        switch hotKeyID.id {
        case 1: delegate.togglePanel()
        case 2: delegate.toggleCapture()
        default: break
        }
    }
    return noErr
}

private final class FloatingClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = ClipboardManager()
    private var screenshotMonitor: ScreenshotMonitor?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var screenshotHotKey: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var screenshotProcess: Process?
    private var capturePanel: NSPanel?
    private var captureKind: CaptureKind = .image
    private let regionSelector = RegionSelector()
    private let recorder = ScreenRecorder()
    private var keyboardMonitor: Any?
    private var activationObserver: Any?
    private var deactivationObserver: Any?
    private var previousAppPID: pid_t?
    private var terminateAfterRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        installHotKeys()
        installKeyboardHandling()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.previousAppPID = pid }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.panel?.orderOut(nil) }
        }
        manager.onSelect = { [weak self] in self?.finishSelection() }
        manager.onScreenshotRequest = { [weak self] in self?.toggleCapture() }
        recorder.onRecordingChanged = { [weak self] active in
            guard let button = self?.statusItem?.button else { return }
            button.image = NSImage(systemSymbolName: active ? "stop.circle.fill" : "doc.on.clipboard",
                                   accessibilityDescription: active ? "録画を停止" : "クリップボード履歴")
            button.image?.isTemplate = true
            button.toolTip = active ? "録画中 · クリックまたは ⌥⇧S で停止" : "履歴 ⌥V · 撮影 ⌥⇧S"
        }
        recorder.onSaved = { [weak self] url in
            self?.manager.addRecordedVideo(at: url)
            if self?.terminateAfterRecording == true { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        recorder.onError = { [weak self] message in
            guard let self else { return }
            self.manager.errorMessage = message
            if self.terminateAfterRecording {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if self.panel?.isVisible != true {
                self.togglePanel()
            }
        }
        manager.startMonitoring()
        screenshotMonitor = ScreenshotMonitor(
            onAccessError: { [weak self] _ in
                self?.manager.errorMessage = "スクリーンショットの保存先を読み取れません。macOS の設定で、このアプリに保存先フォルダーへのアクセスを許可してください。"
            },
            onScreenshot: { [weak self] url in
                await self?.manager.importScreenshot(at: url) ?? false
            }
        )
        screenshotMonitor?.start()
        DispatchQueue.main.async { [weak self] in self?.togglePanel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenshotMonitor?.stop()
        regionSelector.cancel()
        manager.stopMonitoring()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let screenshotHotKey { UnregisterEventHotKey(screenshotHotKey) }
        if let hotKeyEventHandler { RemoveEventHandler(hotKeyEventHandler) }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording || recorder.isFinishing {
            terminateAfterRecording = true
            if recorder.isRecording { recorder.stop() }
            return .terminateLater
        }
        return .terminateNow
    }

    @objc private func togglePanelFromStatusItem() {
        if recorder.isRecording { recorder.stop() }
        else if !recorder.isFinishing { togglePanel() }
    }

    func togglePanel() {
        if capturePanel?.isVisible == true || regionSelector.isSelecting { closeCapture() }
        if panel?.isVisible == true {
            closePanel(restoreFocus: true)
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousAppPID = front.processIdentifier
        }
        manager.query = ""
        manager.selectedID = nil
        manager.refreshPermissions()
        let panel = makePanel()
        panel.contentView = NSHostingView(rootView: HistoryView(manager: manager))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func toggleCapture() {
        if recorder.isRecording { recorder.stop(); return }
        if recorder.isFinishing { return }
        if capturePanel?.isVisible == true || regionSelector.isSelecting {
            closeCapture()
            return
        }
        panel?.orderOut(nil)
        captureKind = .image
        let capturePanel = makeCapturePanel()
        capturePanel.contentView = NSHostingView(rootView: CaptureView(
            select: { [weak self] kind, mode in self?.selectCapture(kind: kind, mode: mode) },
            cancel: { [weak self] in self?.closeCapture() }
        ))
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let screen {
            capturePanel.setFrameOrigin(NSPoint(x: screen.frame.midX - capturePanel.frame.width / 2,
                                               y: screen.visibleFrame.maxY - capturePanel.frame.height - 12))
        }
        capturePanel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        beginRegionSelection()
    }

    private func selectCapture(kind: CaptureKind, mode: CaptureMode) {
        captureKind = kind
        guard mode != .region else { return }
        closeCapture()
        if kind == .video {
            recorder.pick(mode)
            return
        }
        if mode == .display {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.startScreenshot(mode) }
        } else {
            startScreenshot(mode)
        }
    }

    private func beginRegionSelection() {
        regionSelector.begin { [weak self] screen, region in
            guard let self else { return }
            let kind = self.captureKind
            self.closeCapture()
            if kind == .video {
                self.recorder.record(screen: screen, region: region)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.startScreenshot(screen: screen, region: region)
                }
            }
        }
    }

    private func closeCapture() {
        regionSelector.cancel()
        capturePanel?.orderOut(nil)
    }

    private func startScreenshot(screen: NSScreen, region: CGRect) {
        guard let rectangle = CaptureGeometry.screenshotRectangle(screen: screen, region: region) else {
            showScreenshotError("撮影する画面を確認できませんでした。")
            return
        }
        runScreenshot(arguments: ["-R", rectangle])
    }

    private func startScreenshot(_ mode: CaptureMode) {
        let arguments: [String]
        switch mode {
        case .region: arguments = ["-i", "-s"]
        case .window: arguments = ["-i", "-w"]
        case .display:
            let screenIndex = NSScreen.screens.firstIndex(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? 0
            arguments = ["-D", String(screenIndex + 1)]
        }
        runScreenshot(arguments: arguments)
    }

    private func runScreenshot(arguments: [String]) {
        guard screenshotProcess == nil else { return }
        guard let directory = ScreenshotStorage.destinationDirectory(),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            showScreenshotError("スクリーンショットの保存先フォルダーが見つかりません。")
            return
        }
        let outputURL = ScreenshotStorage.newCaptureURL(in: directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + ["-t", "png", outputURL.path]
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screenshotProcess = nil
                if finished.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path) {
                    if !self.manager.useSavedScreenshot(at: outputURL) {
                        self.showScreenshotError(self.manager.errorMessage ?? "スクリーンショットを読み込めませんでした。")
                    }
                } else {
                    if finished.terminationStatus != 0 { try? FileManager.default.removeItem(at: outputURL) }
                    if !arguments.contains("-i") {
                        self.showScreenshotError("スクリーンショットを保存できませんでした。")
                    }
                }
            }
        }
        screenshotProcess = process
        do {
            try process.run()
        } catch {
            screenshotProcess = nil
            showScreenshotError("スクリーンショットを開始できませんでした。")
        }
    }

    private func showScreenshotError(_ message: String) {
        manager.errorMessage = message
        if panel?.isVisible != true { togglePanel() }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "クリップボード履歴")
            button.image?.isTemplate = true
            button.toolTip = "履歴 ⌥V · 撮影 ⌥⇧S"
            button.target = self
            button.action = #selector(togglePanelFromStatusItem)
        }
        statusItem = item
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let created = FloatingClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.isMovableByWindowBackground = true
        created.isFloatingPanel = true
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.hidesOnDeactivate = true
        panel = created
        return created
    }

    private func makeCapturePanel() -> NSPanel {
        if let capturePanel { return capturePanel }
        let created = FloatingClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 354, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        capturePanel = created
        return created
    }

    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &hotKeyEventHandler
        )
        guard handlerStatus == noErr else {
            manager.errorMessage = "ショートカットを登録できませんでした。"
            return
        }

        let historyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V), UInt32(optionKey),
            EventHotKeyID(signature: OSType(0x43464D43), id: 1),
            GetApplicationEventTarget(), 0, &hotKey
        )
        if historyStatus != noErr {
            manager.errorMessage = "⌥V を登録できませんでした。ほかのアプリとショートカットが重複している可能性があります。メニューバーのアイコンから履歴を開けます。"
        }
        let screenshotStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S), UInt32(optionKey | shiftKey),
            EventHotKeyID(signature: OSType(0x43464D43), id: 2),
            GetApplicationEventTarget(), 0, &screenshotHotKey
        )
        if screenshotStatus != noErr {
            manager.errorMessage = "⌥⇧S を登録できませんでした。ほかのアプリとショートカットが重複している可能性があります。"
        }
    }

    private func installKeyboardHandling() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.regionSelector.isSelecting, Int(event.keyCode) == kVK_Escape {
                self.closeCapture()
                return nil
            }
            if self.capturePanel?.isVisible == true {
                if Int(event.keyCode) == kVK_Escape {
                    self.closeCapture()
                    return nil
                }
                return event
            }
            guard self.panel?.isVisible == true else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.closePanel(restoreFocus: true)
                return nil
            case kVK_DownArrow:
                self.manager.moveSelection(by: 1)
                return nil
            case kVK_UpArrow:
                self.manager.moveSelection(by: -1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.manager.selectCurrent()
                return nil
            default:
                return event
            }
        }
    }

    private func closePanel(restoreFocus: Bool) {
        panel?.orderOut(nil)
        if restoreFocus, let pid = previousAppPID {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    private func finishSelection() {
        let target = previousAppPID
        panel?.orderOut(nil)
        guard let target,
              let application = NSRunningApplication(processIdentifier: target) else { return }
        guard application.activate() else { return }
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
