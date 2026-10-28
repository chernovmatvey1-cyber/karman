import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let detector = ShakeDetector()
    private var hotKeys: [HotKey] = []
    private var controllers: [PocketController] = []
    private let maxPockets = 8
    private var releaseWatch: Timer?
    /// Без App Nap: иначе система копит события мыши и карман опаздывает.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Следит за встряхиванием курсора")
        setUpStatusItem()
        restore()
        collectGarbage()

        detector.onShake = { [weak self] point, withFile in self?.summonPocket(at: point, ephemeral: withFile) }
        detector.start()

        // ⌃⌥D — карман под курсором, ⌃⌥S — скриншот сразу в карман.
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey) { [weak self] in
                self?.summonPocket(at: NSEvent.mouseLocation)
            },
            HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in
                self?.screenshotToPocket()
            },
        ]
    }

    func applicationWillTerminate(_ notification: Notification) {
        save()
    }

    // MARK: Карманы

    /// Встряхнули курсор: пустой карман переезжает к нему, иначе появляется новый.
    /// С файлом в руке карман временный: отпустили мимо — он исчезает.
    @discardableResult
    func summonPocket(at point: NSPoint, ephemeral: Bool = false) -> PocketController? {
        defer {
            if Settings.playSound { NSSound(named: "Pop")?.play() }
            if ephemeral { watchForRelease() }
        }
        if let empty = controllers.first(where: { $0.pocket.items.isEmpty }) {
            empty.ephemeral = ephemeral
            empty.pocket.received = false
            empty.move(centeredAt: point)
            return empty
        } else {
            if controllers.count >= maxPockets, let oldest = controllers.first(where: { !$0.panel.isKeyWindow }) {
                oldest.close()
            }
            let pocket = Pocket()
            let origin = PocketController.origin(centeredAt: point, size: PocketController.compactSize)
            let controller = open(pocket, at: origin, from: point)
            controller.ephemeral = ephemeral
            return controller
        }
    }

    /// Ждёт, пока отпустят кнопку мыши, и убирает временные карманы, на которые ничего не бросили.
    /// Карманы с файлами остаются на месте, чтобы ничего не мелькало и не терялось.
    private func watchForRelease() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self?.releaseWatch = nil
            // Бросок в карман обрабатывается сразу после отпускания; даём ему время.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                for c in self.controllers where c.ephemeral {
                    c.ephemeral = false
                    if c.pocket.items.isEmpty && !c.pocket.received && !c.pocket.busy { c.close() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    /// Снимает выделенную область и кладёт снимок в карман под курсором.
    func screenshotToPocket() {
        Screenshots.capture { [weak self] url in
            guard let url, let self else { return }
            self.summonPocket(at: NSEvent.mouseLocation)?.pocket.add([PocketItem(kind: .file(url), owned: true)])
        }
    }

    @discardableResult
    private func open(_ pocket: Pocket, at origin: NSPoint, from point: NSPoint? = nil) -> PocketController {
        let controller = PocketController(pocket: pocket, origin: origin)
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.save()
        }
        controller.onMoved = { [weak self] in self?.save() }
        pocket.onChange = { [weak self] in self?.save() }
        pocket.onEmptiedByDrag = { [weak controller] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let controller, controller.pocket.items.isEmpty else { return }
                controller.close()
            }
        }
        controllers.append(controller)
        controller.show(from: point)
        save()
        return controller
    }

    @discardableResult
    @objc private func newPocketFromMenu() -> PocketController? {
        let vf = NSScreen.main?.visibleFrame ?? .zero
        return summonPocket(at: NSPoint(x: vf.maxX - 140, y: vf.maxY - 150))
    }

    // MARK: Сохранение между запусками

    private struct SavedPocket: Codable {
        var id: UUID
        var x: Double
        var y: Double
        var expanded: Bool
        var items: [PocketItem.Record]
    }

    private func save() {
        let saved = controllers.filter { !$0.pocket.items.isEmpty }.map { c in
            SavedPocket(id: c.pocket.id, x: c.pocketFrame.minX, y: c.pocketFrame.minY,
                        expanded: c.pocket.expanded, items: c.pocket.items.map(\.record))
        }
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Storage.stateFile, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Storage.stateFile),
              let saved = try? JSONDecoder().decode([SavedPocket].self, from: data) else { return }
        for s in saved {
            let pocket = Pocket(id: s.id, items: s.items.map(PocketItem.init(record:)))
            pocket.dropMissing()
            guard !pocket.items.isEmpty else { continue }
            pocket.expanded = s.expanded
            open(pocket, at: NSPoint(x: s.x, y: s.y))
        }
    }

    /// Удаляет из папки приложения файлы, которых уже нет ни в одном кармане.
    private func collectGarbage() {
        let alive = Set(controllers.flatMap { $0.pocket.fileURLs }
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

        let new = ClosureMenuItem("Новый карман", symbol: "tray") { [weak self] in self?.newPocketFromMenu() }
        new.keyEquivalent = "d"
        new.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(new)
        let shot = ClosureMenuItem("Скриншот в карман", symbol: "camera.viewfinder") { [weak self] in self?.screenshotToPocket() }
        shot.keyEquivalent = "s"
        shot.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(shot)
        menu.addItem(ClosureMenuItem("Последний скриншот в карман", symbol: "photo") { [weak self] in
            guard let self else { return }
            guard let url = Screenshots.latest() else { NSSound.beep(); return }
            self.newPocketFromMenu()?.pocket.add([PocketItem(kind: .file(url))])
        })
        menu.addItem(ClosureMenuItem("Закрыть все карманы", enabled: !controllers.isEmpty) { [weak self] in
            self?.controllers.forEach { $0.close() }
        })

        menu.addItem(.separator())
        menu.addItem(sectionTitle("Карман по встряхиванию курсора"))
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
        menu.addItem(ClosureMenuItem("Убирать из кармана после перетаскивания", state: Settings.removeAfterDrag) {
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
