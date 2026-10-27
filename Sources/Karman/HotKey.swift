import Carbon.HIToolbox

/// Глобальное сочетание клавиш через Carbon: работает без разрешений.
final class HotKey {
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        Self.registry[id] = self
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B52_4D4E), id: id) // 'KRMN'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    /// Один обработчик на всё приложение: по номеру находит нужное сочетание.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.registry[id]?.action() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
