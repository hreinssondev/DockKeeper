import AppKit
import Carbon

struct DockMoverShortcut: Codable, Equatable {
    static let settingsDefault = DockMoverShortcut(
        keyCode: UInt16(kVK_ANSI_9),
        modifiers: [.command, .shift]
    )

    private static let supportedModifiers: NSEvent.ModifierFlags = [
        .command,
        .shift,
        .option,
        .control
    ]

    let keyCode: UInt16
    let modifierRawValue: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty,
              Self.keyLabel(for: event.keyCode) != nil else {
            return nil
        }

        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    var displayText: String {
        var pieces: [String] = []
        let modifierFlags = NSEvent.ModifierFlags(rawValue: modifierRawValue)

        if modifierFlags.contains(.command) {
            pieces.append("Cmd")
        }
        if modifierFlags.contains(.shift) {
            pieces.append("Shift")
        }
        if modifierFlags.contains(.option) {
            pieces.append("Option")
        }
        if modifierFlags.contains(.control) {
            pieces.append("Ctrl")
        }
        if let keyLabel = Self.keyLabel(for: keyCode) {
            pieces.append(keyLabel)
        }

        return pieces.joined(separator: "+")
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        let modifierFlags = NSEvent.ModifierFlags(rawValue: modifierRawValue)

        if modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }

        return modifiers
    }

    static func isCommitKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    static func isCancelKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Escape)
    }

    private static func keyLabel(for keyCode: UInt16) -> String? {
        keyLabels[keyCode]
    }

    private static let keyLabels: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A",
        UInt16(kVK_ANSI_B): "B",
        UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E",
        UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G",
        UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J",
        UInt16(kVK_ANSI_K): "K",
        UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M",
        UInt16(kVK_ANSI_N): "N",
        UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q",
        UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S",
        UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V",
        UInt16(kVK_ANSI_W): "W",
        UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y",
        UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0",
        UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4",
        UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6",
        UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_LeftArrow): "Left",
        UInt16(kVK_RightArrow): "Right",
        UInt16(kVK_UpArrow): "Up",
        UInt16(kVK_DownArrow): "Down",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20"
    ]
}

final class GlobalShortcutRegistrar {
    var action: (() -> Void)?

    private let hotKeySignature = fourCharCode("DMvR")
    private let hotKeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(_ shortcut: DockMoverShortcut) -> OSStatus {
        installEventHandlerIfNeeded()
        unregister()

        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIdentifier)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            self.hotKeyRef = hotKeyRef
        }

        return status
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    fileprivate func handleEvent(_ event: EventRef?) -> OSStatus {
        guard let event,
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == hotKeySignature,
              hotKeyID.id == hotKeyIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        action?()
        return noErr
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            globalShortcutEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status == noErr {
            self.eventHandlerRef = eventHandlerRef
        }
    }
}

private let globalShortcutEventHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else {
        return noErr
    }

    let registrar = Unmanaged<GlobalShortcutRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return registrar.handleEvent(event)
}

private func fourCharCode(_ code: String) -> OSType {
    code.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
