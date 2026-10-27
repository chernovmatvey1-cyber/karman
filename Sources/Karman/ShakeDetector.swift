import AppKit

/// Замечает, когда курсором резко водят туда-сюда.
/// Глобальный монитор движения мыши не требует никаких разрешений.
final class ShakeDetector {
    /// Точка встряхивания и зажата ли при этом кнопка мыши (несут файл).
    var onShake: ((NSPoint, Bool) -> Void)?

    private var monitors: [Any] = []
    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var segmentStartX: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var cooldownUntil: TimeInterval = 0
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount

    func start() {
        guard monitors.isEmpty else { return }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func reset() {
        lastX = nil
        direction = 0
        reversals.removeAll()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Новое перетаскивание после этого нажатия изменит счётчик.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            reset()
            return
        }
        let mode = Settings.shakeMode
        if mode == .off { return }
        let dragging = event.type == .leftMouseDragged
        if mode == .whileDragging {
            // Перетаскивание файла или картинки меняет специальный буфер обмена.
            guard dragging, NSPasteboard(name: .drag).changeCount != dragChangeCount else { reset(); return }
        }

        // Координаты и время берутся из самого события: когда система
        // доставляет события пачкой, текущая позиция курсора у всех одна.
        let now = event.timestamp
        if now < cooldownUntil { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let x = point.x
        defer { lastX = x }
        guard let last = lastX else { segmentStartX = x; return }
        let dx = x - last
        if abs(dx) < 2 { return }
        let dir: CGFloat = dx > 0 ? 1 : -1

        if direction == 0 {
            direction = dir
            segmentStartX = last
            return
        }
        guard dir != direction else { return }

        let sens = Settings.sensitivity
        if abs(last - segmentStartX) >= sens.minDistance {
            reversals.append(now)
        }
        direction = dir
        segmentStartX = last
        reversals.removeAll { now - $0 > sens.window }

        if reversals.count >= sens.reversals {
            reset()
            cooldownUntil = now + 0.8
            onShake?(point, dragging)
        }
    }
}
