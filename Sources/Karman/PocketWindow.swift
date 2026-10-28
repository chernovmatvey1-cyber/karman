import AppKit
import Quartz
import SwiftUI

/// Плавающая панель, которая не забирает фокус у текущего приложения
/// и видна на всех рабочих столах, в том числе поверх полноэкранных окон.
final class PocketPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Один карман на экране: окно, его содержимое и действия, которым нужно окно.
final class PocketController: NSObject {
    static let compactSize = PocketLayout.compact
    static let expandedSize = PocketLayout.expanded

    let pocket: Pocket
    let panel: PocketPanel
    /// Сам карман. Вокруг него в окне прозрачный запас, чтобы пружинке
    /// и размытию было куда выходить и углы не обрезались окном.
    private let container: PocketContainerView
    static let margin: CGFloat = 28
    private var closing = false
    /// Карман вызван встряхиванием с файлом: исчезнет, если файл бросили мимо.
    var ephemeral = false
    var onClose: ((PocketController) -> Void)?
    var onMoved: (() -> Void)?

    init(pocket: Pocket, origin: NSPoint) {
        self.pocket = pocket
        let size = pocket.expanded ? Self.expandedSize : Self.compactSize
        let m = Self.margin
        panel = PocketPanel(frame: NSRect(origin: origin, size: size).insetBy(dx: -m, dy: -m))
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container = PocketContainerView(frame: root.bounds.insetBy(dx: m, dy: m))
        super.init()
        container.controller = self
        container.wantsLayer = true
        container.layerUsesCoreImageFilters = true
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)

        let glass = NSVisualEffectView(frame: container.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .vibrantDark)
        glass.maskImage = Self.roundedMask(radius: PocketLayout.radius)
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let host = NSHostingView(rootView: PocketView(pocket: pocket, actions: self))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        panel.contentView = root
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
    }

    /// Появляется каплей из центра: маленькая размытая капля раздувается
    /// в квадрат, пружинит как желе и становится резкой — будто вынырнула из экрана.
    func show(from point: NSPoint? = nil) {
        closing = false
        panel.hasShadow = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard let layer = container.layer else { return }
        layer.removeAllAnimations()
        let b = container.bounds
        let center = CGPoint(x: b.midX, y: b.midY)

        // Форма: из круглой капли в скруглённый квадрат.
        let mask = CAShapeLayer()
        mask.frame = b
        mask.path = Self.roundedPath(b, radius: PocketLayout.radius)
        layer.mask = mask
        let morph = CASpringAnimation(keyPath: "path")
        morph.fromValue = Self.droplet(center, diameter: 26)
        morph.toValue = mask.path
        morph.mass = 0.8
        morph.stiffness = 190
        morph.damping = 19
        morph.duration = morph.settlingDuration
        mask.add(morph, forKey: "morph")

        // Желейное покачивание: сплющилась, вытянулась, успокоилась.
        let jelly = CAKeyframeAnimation(keyPath: "transform")
        jelly.values = [(0.5, 0.5), (1.07, 0.93), (0.96, 1.04), (1.015, 0.99), (1, 1)]
            .map { Self.scale($0.0, $0.1, around: center) }
        jelly.keyTimes = [0, 0.38, 0.6, 0.8, 1]
        jelly.duration = 0.62
        jelly.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: 4)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12

        // Проявляется из размытия.
        layer.filters = [Self.blurFilter()]
        let unblur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        unblur.fromValue = 14
        unblur.toValue = 0
        unblur.duration = 0.32
        unblur.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.closing else { return }
            layer.mask = nil
            layer.filters = nil
            self.panel.hasShadow = true
            self.panel.invalidateShadow()
        }
        layer.add(jelly, forKey: "jelly")
        layer.add(fade, forKey: "fade")
        layer.add(unblur, forKey: "unblur")
        CATransaction.commit()
    }

    /// Где на экране сам карман, без прозрачного запаса.
    var pocketFrame: NSRect { panel.frame.insetBy(dx: Self.margin, dy: Self.margin) }

    func move(centeredAt point: NSPoint) {
        let o = Self.origin(centeredAt: point, size: pocketFrame.size)
        panel.setFrameOrigin(NSPoint(x: o.x - Self.margin, y: o.y - Self.margin))
        show(from: point)
    }

    /// Уходит обратно в экран: стягивается в каплю к центру, размывается и тонет.
    func close() {
        guard !closing else { return }
        closing = true
        NotificationCenter.default.removeObserver(self)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        let finish = { [self] in
            panel.orderOut(nil)
            onClose?(self)
        }
        guard let layer = container.layer else { finish(); return }
        layer.removeAllAnimations()
        panel.hasShadow = false
        let b = container.bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        let duration = 0.34
        let sink = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.75, 0.2)

        let mask = CAShapeLayer()
        mask.frame = b
        mask.path = Self.droplet(center, diameter: 18)
        layer.mask = mask
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue = Self.roundedPath(b, radius: PocketLayout.radius)
        morph.toValue = mask.path
        morph.duration = duration
        morph.timingFunction = sink
        mask.add(morph, forKey: "morph")

        // Перед уходом чуть набирает воздуха, потом проваливается.
        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [(1, 1), (1.04, 1.04), (0.7, 0.7)].map { Self.scale($0.0, $0.1, around: center) }
        squash.keyTimes = [0, 0.18, 1]
        squash.duration = duration
        squash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), sink]

        layer.filters = [Self.blurFilter()]
        let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        blur.fromValue = 0
        blur.toValue = 10
        blur.duration = duration
        blur.timingFunction = sink

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + duration * 0.55
        fade.duration = duration * 0.45

        for a in [squash, blur, fade] as [CAAnimation] {
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        layer.add(squash, forKey: "squash")
        layer.add(blur, forKey: "blur")
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Круг, собранный тем же способом, что и скруглённый квадрат, чтобы форма плавно перетекала.
    private static func droplet(_ c: CGPoint, diameter d: CGFloat) -> CGPath {
        roundedPath(CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), radius: d / 2 - 0.01)
    }

    private static func blurFilter() -> CIFilter {
        let f = CIFilter(name: "CIGaussianBlur")!
        f.setValue(0, forKey: kCIInputRadiusKey)
        f.name = "blur"
        return f
    }

    private static func scale(_ sx: CGFloat, _ sy: CGFloat, around p: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, sx, sy, 1)
        return CATransform3DTranslate(t, -p.x, -p.y, 0)
    }

    @objc private func windowMoved() { onMoved?() }

    /// Позиция окна так, чтобы курсор оказался внутри кармана, но не за краем экрана.
    static func origin(centeredAt p: NSPoint, size: NSSize) -> NSPoint {
        var origin = NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2 - 20)
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return origin
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: Действия, вызываемые из интерфейса

extension PocketController: PocketActions {
    func closePocket() { close() }

    func run(_ action: PocketAction) {
        pocket.perform(action, on: pocket.targets)
    }

    func toggleExpanded() {
        let expanded = !pocket.expanded
        let size = expanded ? Self.expandedSize : Self.compactSize
        let old = pocketFrame
        var frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        if let vf = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vf.minX + 8), vf.maxX - size.width - 8)
            frame.origin.y = max(frame.minY, vf.minY + 8)
        }
        pocket.selection.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { pocket.expanded = expanded }
        panel.setFrame(frame.insetBy(dx: -Self.margin, dy: -Self.margin), display: true, animate: true)
        pocket.onChange?()
    }

    func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let has = !pocket.items.isEmpty
        let hasFiles = !pocket.fileURLs.isEmpty
        let hasImages = pocket.fileURLs.contains(where: Processing.isImage)

        menu.addItem(ClosureMenuItem("Быстрый просмотр", key: " ", symbol: "eye", enabled: hasFiles) { [weak self] in self?.quickLook() })
        menu.addItem(ClosureMenuItem("Открыть", symbol: "arrow.up.forward.app", enabled: has) { [weak self] in self?.pocket.open() })
        menu.addItem(ClosureMenuItem("Показать в Finder", symbol: "folder", enabled: hasFiles) { [weak self] in self?.pocket.revealInFinder() })

        menu.addItem(.separator())
        for action in PocketAction.allCases {
            let enabled = action.needsImages ? hasImages : hasFiles
            menu.addItem(ClosureMenuItem(action.menuTitle, symbol: action.symbol, enabled: enabled) { [weak self] in
                guard let self else { return }
                self.pocket.perform(action, on: self.pocket.targets)
            })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("AirDrop", symbol: "airplayaudio", enabled: hasFiles) { [weak self] in self?.pocket.airDrop() })
        menu.addItem(ClosureMenuItem("Поделиться…", symbol: "square.and.arrow.up", enabled: has) { [weak self] in self?.share() })
        menu.addItem(ClosureMenuItem("Скопировать", key: "c", symbol: "doc.on.doc", enabled: has) { [weak self] in self?.pocket.copyToPasteboard() })
        menu.addItem(ClosureMenuItem("Скопировать путь", symbol: "link", enabled: hasFiles) { [weak self] in self?.pocket.copyPaths() })
        menu.addItem(ClosureMenuItem("Сохранить в папку…", symbol: "square.and.arrow.down", enabled: has) { [weak self] in self?.saveToFolder() })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Вставить из буфера", key: "v", symbol: "doc.on.clipboard") { [weak self] in self?.paste() })
        menu.addItem(ClosureMenuItem("Снять скриншот сюда", symbol: "camera.viewfinder") { [weak self] in self?.captureScreenshot() })
        menu.addItem(ClosureMenuItem("Добавить последний скриншот", symbol: "photo") { [weak self] in self?.addLatestScreenshot() })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(pocket.expanded ? "Свернуть в стопку" : "Показать все",
                                     symbol: pocket.expanded ? "square.stack" : "list.bullet", enabled: has) { [weak self] in
            self?.toggleExpanded()
        })
        menu.addItem(ClosureMenuItem("Очистить карман", symbol: "trash", enabled: has) { [weak self] in self?.pocket.clear() })
        menu.addItem(ClosureMenuItem("Закрыть карман", key: "w", symbol: "xmark") { [weak self] in self?.close() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func captureScreenshot() {
        panel.orderOut(nil)
        Screenshots.capture { [weak self] url in
            guard let self else { return }
            self.panel.orderFrontRegardless()
            if let url { self.pocket.add([PocketItem(kind: .file(url), owned: true)]) }
        }
    }

    func remove(_ item: PocketItem) {
        pocket.remove([item.id])
    }

    func paste() {
        if pocket.ingest(from: .general) { pocket.received = true } else { NSSound.beep() }
    }

    func addLatestScreenshot() {
        if let url = Screenshots.latest() {
            pocket.add([PocketItem(kind: .file(url))])
        } else {
            NSSound.beep()
        }
    }

    func quickLook() {
        guard !pocket.fileURLs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.makeFirstResponder(container)
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    func share() {
        let objects: [Any] = pocket.targets.map { item -> Any in
            switch item.kind { case .file(let u), .link(let u): return u }
        }
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: objects)
        picker.show(relativeTo: NSRect(x: container.bounds.midX - 1, y: 20, width: 2, height: 2),
                    of: container, preferredEdge: .minY)
    }

    func saveToFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Сохранить сюда"
        open.message = "Куда скопировать \(pluralRu(pocket.items.count, "объект", "объекта", "объектов"))?"
        if open.runModal() == .OK, let folder = open.url {
            pocket.copy(to: folder)
        }
    }
}

// MARK: Корневой вид окна: принимает перетаскивание и клавиши

final class PocketContainerView: NSView {
    weak var controller: PocketController?
    private var pocket: Pocket? { controller?.pocket }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Pocket.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Наведение: показывает кнопки, даже когда окно не активно.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pocket?.hovering = true }
    override func mouseExited(with event: NSEvent) { pocket?.hovering = false }

    // Перетаскивание внутрь.

    private func action(at sender: NSDraggingInfo) -> PocketAction? {
        let p = convert(sender.draggingLocation, from: nil)
        return PocketLayout.tile(at: p, width: bounds.width).map { PocketAction.instant[$0] }
    }

    /// Объекты из этого же кармана: их можно бросить только на плитку действия.
    private func isOwn(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? ItemDragView)?.pocket === pocket
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pocket?.isTargeted = true
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pocket else { return [] }
        let action = action(at: sender)
        if pocket.dropAction != action { pocket.dropAction = action }
        return isOwn(sender) && action == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pocket?.isTargeted = false
        pocket?.dropAction = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        pocket?.isTargeted = false
        pocket?.dropAction = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pocket else { return false }
        let action = action(at: sender)
        pocket.isTargeted = false
        pocket.dropAction = nil
        if isOwn(sender) && action == nil { return false }
        let ok = pocket.ingest(from: sender.draggingPasteboard, then: action)
        if ok { pocket.received = true }
        return ok
    }

    // Клавиши.

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: controller?.quickLook()                 // пробел
        case 53: controller?.close()                     // Esc
        case 51, 117: pocket?.clear()                     // Delete
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": controller?.paste(); return true
        case "c": pocket?.copyToPasteboard(); return true
        case "w": controller?.close(); return true
        case "a": return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // Быстрый просмотр.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

extension PocketContainerView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        pocket?.fileURLs.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        pocket?.fileURLs[index] as NSURL?
    }
}

// MARK: Перетаскивание наружу

/// Прозрачный слой над стопкой или строкой списка, из которого объекты
/// вытаскиваются в Finder, мессенджер, почту и так далее.
final class ItemDragView: NSView, NSDraggingSource {
    weak var pocket: Pocket?
    var items: () -> [PocketItem] = { [] }
    var onDoubleClick: (() -> Void)?
    /// Обычный клик без перетаскивания; аргумент — зажат ли ⌘ или ⇧.
    var onClick: ((Bool) -> Void)?
    private var downEvent: NSEvent?
    private var dragging: [PocketItem] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        downEvent = nil
        dragging = items()
        guard !dragging.isEmpty else { return }

        let point = convert(event.locationInWindow, from: nil)
        let draggingItems = dragging.enumerated().map { index, item -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
            let side: CGFloat = 72
            let shift = CGFloat(min(index, 4)) * 5
            d.setDraggingFrame(NSRect(x: point.x - side / 2 + shift, y: point.y - side / 2 - shift,
                                      width: side, height: side), contents: item.thumbnail)
            return d
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, event.clickCount == 1 {
            onClick?(!event.modifierFlags.intersection([.command, .shift]).isEmpty)
        }
        downEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { dragging = [] }
        guard !operation.isEmpty, Settings.removeAfterDrag, let pocket else { return }
        // Объект сам по себе возвращённый в тот же карман не убираем.
        if let window, NSMouseInRect(screenPoint, window.frame, false) { return }
        withAnimation(.easeOut(duration: 0.2)) {
            pocket.remove(Set(dragging.map(\.id)), byDrag: true)
        }
    }
}

// MARK: Меню с замыканиями

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", symbol: String? = nil, enabled: Bool = true, state: Bool? = nil,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        target = self
        isEnabled = enabled
        if let state { self.state = state ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
