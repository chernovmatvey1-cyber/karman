import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let detector = ShakeDetector()
    private var hotKeys: [HotKey] = []
    private var controllers: [ShelfController] = []
    private let maxShelves = 8
    private var releaseWatch: Timer?
    /// Без App Nap: иначе система копит события мыши и полка опаздывает.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Следит за встряхиванием курсора")
        setUpStatusItem()
        restore()
        collectGarbage()

        detector.onShake = { [weak self] point, withFile in self?.summonShelf(at: point, ephemeral: withFile) }
        detector.start()

        // ⌃⌥D — полка под курсором, ⌃⌥S — скриншот сразу на полку.
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey) { [weak self] in
                self?.summonShelf(at: NSEvent.mouseLocation)
            },
            HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in
                self?.screenshotToShelf()
            },
        ]
    }

    func applicationWillTerminate(_ notification: Notification) {
        save()
    }

    // MARK: Полки

    /// Встряхнули курсор: пустая полка переезжает к нему, иначе появляется новая.
    /// С файлом в руке полка временная: отпустили мимо — она исчезает.
    @discardableResult
    func summonShelf(at point: NSPoint, ephemeral: Bool = false) -> ShelfController? {
        defer {
            if Settings.playSound { NSSound(named: "Pop")?.play() }
            if ephemeral { watchForRelease() }
        }
        if let empty = controllers.first(where: { $0.shelf.items.isEmpty }) {
            empty.ephemeral = ephemeral
            empty.shelf.received = false
            empty.move(centeredAt: point)
            return empty
        } else {
            if controllers.count >= maxShelves, let oldest = controllers.first(where: { !$0.panel.isKeyWindow }) {
                oldest.close()
            }
            let shelf = Shelf()
            let origin = ShelfController.origin(centeredAt: point, size: ShelfController.compactSize)
            let controller = open(shelf, at: origin, from: point)
            controller.ephemeral = ephemeral
            return controller
        }
    }

    /// Ждёт, пока отпустят кнопку мыши, и убирает временные полки, на которые ничего не бросили.
    /// Полки с файлами остаются на месте, чтобы ничего не мелькало и не терялось.
    private func watchForRelease() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self?.releaseWatch = nil
            // Бросок на полку обрабатывается сразу после отпускания; даём ему время.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                for c in self.controllers where c.ephemeral {
                    c.ephemeral = false
                    if c.shelf.items.isEmpty && !c.shelf.received && !c.shelf.busy { c.close() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    /// Снимает выделенную область и кладёт снимок на полку под курсором.
    func screenshotToShelf() {
        Screenshots.capture { [weak self] url in
            guard let url, let self else { return }
            self.summonShelf(at: NSEvent.mouseLocation)?.shelf.add([ShelfItem(kind: .file(url), owned: true)])
        }
    }

    @discardableResult
    private func open(_ shelf: Shelf, at origin: NSPoint, from point: NSPoint? = nil) -> ShelfController {
        let controller = ShelfController(shelf: shelf, origin: origin)
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.save()
        }
        controller.onMoved = { [weak self] in self?.save() }
        shelf.onChange = { [weak self] in self?.save() }
        shelf.onEmptiedByDrag = { [weak controller] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let controller, controller.shelf.items.isEmpty else { return }
                controller.close()
            }
        }
        controllers.append(controller)
        controller.show(from: point)
        save()
        return controller
    }

    @discardableResult
    @objc private func newShelfFromMenu() -> ShelfController? {
        let vf = NSScreen.main?.visibleFrame ?? .zero
        return summonShelf(at: NSPoint(x: vf.maxX - 140, y: vf.maxY - 150))
    }

    // MARK: Сохранение между запусками

    private struct SavedShelf: Codable {
        var id: UUID
        var x: Double
        var y: Double
        var expanded: Bool
        var items: [ShelfItem.Record]
    }

    private func save() {
        let saved = controllers.filter { !$0.shelf.items.isEmpty }.map { c in
            SavedShelf(id: c.shelf.id, x: c.shelfFrame.minX, y: c.shelfFrame.minY,
                       expanded: c.shelf.expanded, items: c.shelf.items.map(\.record))
        }
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Storage.stateFile, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Storage.stateFile),
              let saved = try? JSONDecoder().decode([SavedShelf].self, from: data) else { return }
        for s in saved {
            let shelf = Shelf(id: s.id, items: s.items.map(ShelfItem.init(record:)))
            shelf.dropMissing()
            guard !shelf.items.isEmpty else { continue }
            shelf.expanded = s.expanded
            open(shelf, at: NSPoint(x: s.x, y: s.y))
        }
    }

    /// Удаляет из папки приложения файлы, которых уже нет ни на одной полке.
    private func collectGarbage() {
        let alive = Set(controllers.flatMap { $0.shelf.fileURLs }
            .map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let folders = (try? FileManager.default.contentsOfDirectory(at: Storage.items, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !alive.contains(folder.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Строка меню

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Карман")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let new = ClosureMenuItem("Новая полка", symbol: "tray") { [weak self] in self?.newShelfFromMenu() }
        new.keyEquivalent = "d"
        new.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(new)
        let shot = ClosureMenuItem("Скриншот на полку", symbol: "camera.viewfinder") { [weak self] in self?.screenshotToShelf() }
        shot.keyEquivalent = "s"
        shot.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(shot)
        menu.addItem(ClosureMenuItem("Последний скриншот на полку", symbol: "photo") { [weak self] in
            guard let self else { return }
            guard let url = Screenshots.latest() else { NSSound.beep(); return }
            self.newShelfFromMenu()?.shelf.add([ShelfItem(kind: .file(url))])
        })
        menu.addItem(ClosureMenuItem("Закрыть все полки", enabled: !controllers.isEmpty) { [weak self] in
            self?.controllers.forEach { $0.close() }
        })

        menu.addItem(.separator())
        menu.addItem(sectionTitle("Полка по встряхиванию курсора"))
        for mode in Settings.ShakeMode.allCases {
            menu.addItem(ClosureMenuItem(mode.title, state: Settings.shakeMode == mode) {
                Settings.shakeMode = mode
            })
        }

        let sensitivity = NSMenuItem(title: "Чувствительность", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in Settings.Sensitivity.allCases {
            sub.addItem(ClosureMenuItem(s.title, state: Settings.sensitivity == s) { Settings.sensitivity = s })
        }
        sensitivity.submenu = sub
        sensitivity.isEnabled = Settings.shakeMode != .off
        menu.addItem(sensitivity)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Убирать с полки после перетаскивания", state: Settings.removeAfterDrag) {
            Settings.removeAfterDrag.toggle()
        })
        menu.addItem(ClosureMenuItem("Звук при появлении", state: Settings.playSound) {
            Settings.playSound.toggle()
        })
        let login = SMAppService.mainApp.status == .enabled
        menu.addItem(ClosureMenuItem("Открывать при входе в систему", state: login) {
            do {
                if login { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            } catch {
                NSSound.beep()
            }
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Выйти из «Кармана»", key: "q") { NSApp.terminate(nil) })
    }

    private func sectionTitle(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
