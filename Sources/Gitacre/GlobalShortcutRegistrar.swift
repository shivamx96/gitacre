import Carbon.HIToolbox
import Foundation

struct GlobalShortcutDefinition {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let showGitacre = GlobalShortcutDefinition(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(cmdKey | optionKey),
        label: "⌥⌘G"
    )
}

/// Registers a real system hot key without observing the user's keyboard events.
///
/// `NSEvent` global key monitors require Accessibility access. Carbon hot-key registration
/// delivers only the chosen shortcut and reports collisions without that permission.
@MainActor
final class GlobalShortcutRegistrar {
    private static let signature = OSType(0x4741_4352) // "GACR"
    private static let identifier: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(definition: GlobalShortcutDefinition, action: @escaping @MainActor () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            context,
            &eventHandler
        ) == noErr else {
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        guard RegisterEventHotKey(
            definition.keyCode,
            definition.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        ) == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            return nil
        }
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func performAction() {
        action()
    }

    private static let handleEvent: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == GlobalShortcutRegistrar.signature,
              identifier.id == GlobalShortcutRegistrar.identifier else {
            return OSStatus(eventNotHandledErr)
        }

        let registrar = Unmanaged<GlobalShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in registrar.performAction() }
        return OSStatus(noErr)
    }
}
