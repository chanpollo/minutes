import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as the Settings shortcut field records it.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    /// The key's character as typed without modifiers, upper-cased ("R").
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option], key: "R")

    /// ⌃⌥⇧⌘ order, as macOS menus show it.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// What a menu item needs to show the same shortcut.
    var menuKeyEquivalent: String {
        switch key {
        case "Space": " "
        case "↩": "\r"
        case "⇥": "\t"
        default: key.lowercased()
        }
    }

    /// A shortcut from a key press, or nil when it lacks ⌘, ⌃ or ⌥ (a plain letter would fire while typing).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty,
              let key = Self.keyName(event), !key.isEmpty
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: key)
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func keyName(_ event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete, kVK_ForwardDelete, kVK_Escape: return nil
        default: break
        }
        // With ⌥ held, `characters` is the option glyph (® for R), and a Thai layout gives พ; the Latin key is wanted.
        let name = latinKey(event.keyCode) ?? event.charactersIgnoringModifiers
        return name?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key's character on the current Latin layout (U.S., ABC…), whatever layout is typing now.
    static func latinKey(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let key = String(utf16CodeUnits: chars, count: length)
        return key.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0.value < 0x20 } ? nil : key
    }
}

extension Settings {
    /// Starts or stops a recording from any app.
    static var recordShortcut: Shortcut {
        get {
            guard let saved = UserDefaults.standard.dictionary(forKey: "recordShortcut"),
                  let code = saved["keyCode"] as? Int, let flags = saved["modifiers"] as? Int, let key = saved["key"] as? String
            else { return .default }
            return Shortcut(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags)), key: key)
        }
        set {
            UserDefaults.standard.set(
                ["keyCode": Int(newValue.keyCode), "modifiers": Int(newValue.modifiers.rawValue), "key": newValue.key],
                forKey: "recordShortcut")
            Hotkey.shared.register(newValue)
        }
    }
}

/// One system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class Hotkey {
    static let shared = Hotkey()

    /// Runs on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    private(set) var isRegistered = false
    /// The last registration was refused, usually because another app holds the same keys.
    private(set) var isTaken = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4D_6E_74_73 // "Mnts"

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        installHandler()
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
        isTaken = !isRegistered
        return isRegistered
    }

    /// While the Settings field records a new shortcut, the old one must not fire.
    func suspend() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func resume() {
        register(Settings.recordShortcut)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.shared.onPress?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
