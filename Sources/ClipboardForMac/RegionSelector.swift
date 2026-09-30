import AppKit

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionSelector {
    private var panels: [NSPanel] = []
    private var completion: ((NSScreen, CGRect) -> Void)?
    private var cursorPushed = false
    var isSelecting: Bool { !panels.isEmpty }

    func begin(_ completion: @escaping (NSScreen, CGRect) -> Void) {
        cancel()
        self.completion = completion
        NSCursor.crosshair.push()
        cursorPushed = true
        for screen in NSScreen.screens {
            let panel = RegionSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in
                guard let self else { return }
                self.cancelPanels()
                self.completion?(screen, rect)
                self.completion = nil
            }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        NSApp.activate()
    }

    func cancel() {
        cancelPanels()
        completion = nil
    }

    private func cancelPanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

private final class RegionSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()
        if let rect = selectedRect {
            NSColor.clear.setFill()
            rect.fill(using: .clear)
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        end = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        guard let rect = selectedRect, rect.width >= 8, rect.height >= 8 else {
            onCancel?()
            return
        }
        onSelect?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    private var selectedRect: CGRect? {
        guard let start, let end else { return nil }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(start.x - end.x), height: abs(start.y - end.y))
            .intersection(bounds)
    }
}
