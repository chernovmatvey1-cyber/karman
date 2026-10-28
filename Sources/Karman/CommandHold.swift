import AppKit

/// Замечает долгое нажатие одной клавиши ⌘ — без других клавиш и кликов.
/// Состояние клавиш читаем опросом: так не нужны никакие разрешения.
final class CommandHold {
    var onHold: (() -> Void)?
    /// Сколько держать ⌘, секунд.
    static let duration: TimeInterval = 0.7

    private var timer: Timer?
    private var pressedAt: TimeInterval?
    private var fired = false

    func start() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let flags = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, Settings.holdCommand else {
            pressedAt = nil
            fired = false
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let start = pressedAt else { pressedAt = now; return }
        let held = now - start
        guard !fired, held >= Self.duration else { return }
        // ⌘C, ⌘Tab, ⌘-клик — это не «подержать ⌘».
        let source = CGEventSourceStateID.combinedSessionState
        let sinceKey = CGEventSource.secondsSinceLastEventType(source, eventType: .keyDown)
        let sinceClick = min(CGEventSource.secondsSinceLastEventType(source, eventType: .leftMouseDown),
                             CGEventSource.secondsSinceLastEventType(source, eventType: .rightMouseDown))
        fired = true
        guard sinceKey > held, sinceClick > held, NSEvent.pressedMouseButtons == 0 else { return }
        onHold?()
    }
}
