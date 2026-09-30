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
        case 2: delegate.startScreenshotSelection()
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
    private var keyboardMonitor: Any?
    private var activationObserver: Any?
    private var deactivationObserver: Any?
    private var previousAppPID: pid_t?

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
        manager.onScreenshotRequest = { [weak self] in self?.startScreenshotSelection() }
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
        manager.stopMonitoring()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let screenshotHotKey { UnregisterEventHotKey(screenshotHotKey) }
        if let hotKeyEventHandler { RemoveEventHandler(hotKeyEventHandler) }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    @objc private func togglePanelFromStatusItem() {
        togglePanel()
    }

    func togglePanel() {
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

    func startScreenshotSelection() {
        guard screenshotProcess == nil else { return }
        if panel?.isVisible == true { closePanel(restoreFocus: true) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-c"]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenshotProcess = nil
                self?.manager.captureCurrentClipboard()
            }
        }
        screenshotProcess = process
        do {
            try process.run()
        } catch {
            screenshotProcess = nil
            manager.errorMessage = "スクリーンショットを開始できませんでした。"
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "クリップボード履歴")
            button.image?.isTemplate = true
            button.toolTip = "履歴 ⌥V · 範囲撮影 ⌥⇧S"
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
            guard let self, self.panel?.isVisible == true else { return event }
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
