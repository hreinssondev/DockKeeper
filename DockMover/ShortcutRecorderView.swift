import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: DockMoverShortcut
    let onCommit: (DockMoverShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderTextField {
        let textField = ShortcutRecorderTextField()
        textField.shortcut = shortcut
        textField.onCommit = onCommit
        textField.refreshDisplay()
        return textField
    }

    func updateNSView(_ textField: ShortcutRecorderTextField, context: Context) {
        textField.shortcut = shortcut
        textField.onCommit = onCommit
        textField.refreshDisplay()
    }
}

final class ShortcutRecorderTextField: NSTextField {
    fileprivate enum Metrics {
        static let controlHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 7
        static let horizontalInset: CGFloat = 14
    }

    var shortcut: DockMoverShortcut = .settingsDefault {
        didSet {
            refreshDisplay()
        }
    }

    var onCommit: ((DockMoverShortcut) -> Void)?

    private var isRecordingShortcut = false
    private var pendingShortcut: DockMoverShortcut?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.controlHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func mouseDown(with event: NSEvent) {
        startRecording()
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        startRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecordingShortcut {
            stopRecording()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        if DockMoverShortcut.isCommitKey(event.keyCode) {
            commitPendingShortcut()
            return
        }

        if DockMoverShortcut.isCancelKey(event.keyCode) {
            stopRecording()
            window?.makeFirstResponder(nil)
            return
        }

        guard let shortcut = DockMoverShortcut(event: event) else {
            NSSound.beep()
            return
        }

        pendingShortcut = shortcut
        refreshDisplay()
    }

    func refreshDisplay() {
        if isRecordingShortcut {
            if let pendingShortcut {
                stringValue = "\(pendingShortcut.displayText)  Enter"
                textColor = .labelColor
            } else {
                stringValue = "Press shortcut"
                textColor = .secondaryLabelColor
            }
        } else {
            stringValue = shortcut.displayText
            textColor = .labelColor
        }

        updateChrome()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        focusRingType = .none
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        lineBreakMode = .byTruncatingTail
        cell = ShortcutRecorderTextFieldCell(textCell: "")
        cell?.alignment = .center
        cell?.font = font
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = "Click, press shortcut, then press Enter"
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Metrics.cornerRadius
        updateChrome()
    }

    private func startRecording() {
        isRecordingShortcut = true
        pendingShortcut = nil
        refreshDisplay()
    }

    private func stopRecording() {
        isRecordingShortcut = false
        pendingShortcut = nil
        refreshDisplay()
    }

    private func commitPendingShortcut() {
        guard let pendingShortcut else {
            NSSound.beep()
            return
        }

        shortcut = pendingShortcut
        stopRecording()
        window?.makeFirstResponder(nil)
        onCommit?(pendingShortcut)
    }

    private func updateChrome() {
        guard let layer else {
            return
        }

        layer.backgroundColor = NSColor.controlColor.cgColor
        layer.borderWidth = isRecordingShortcut ? 2 : 0
        layer.borderColor = isRecordingShortcut
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

}

private final class ShortcutRecorderTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        var drawingRect = super.drawingRect(forBounds: rect)
        drawingRect.origin.y += max(0, (drawingRect.height - textSize.height) / 2)
        drawingRect.size.height = min(drawingRect.height, textSize.height)
        return drawingRect.insetBy(dx: ShortcutRecorderTextField.Metrics.horizontalInset, dy: 0)
    }
}
