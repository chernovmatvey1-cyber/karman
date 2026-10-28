import AppKit
import UniformTypeIdentifiers

/// Содержимое одного кармана.
final class Pocket: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var items: [PocketItem] = []
    @Published var expanded = false
    @Published var isTargeted = false
    /// В карман что-то бросили или вставили: случайным его больше не считаем.
    var received = false
    /// Курсор над карманом: тогда видны кнопки.
    @Published var hovering = false
    /// Над какой плиткой действия сейчас несут объекты; nil — просто в карман.
    @Published var dropAction: PocketAction?
    @Published var busy = false
    /// Выделенные в раскрытом кармане объекты.
    @Published var selection: Set<UUID> = []
    @Published var toast: (text: String, symbol: String)?
    private var toastWork: DispatchWorkItem?

    /// Вызывается при любом изменении, чтобы сохранить состояние.
    var onChange: (() -> Void)?
    /// Карман опустел после того, как всё перетащили наружу.
    var onEmptiedByDrag: (() -> Void)?

    init(id: UUID = UUID(), items: [PocketItem] = []) {
        self.id = id
        self.items = items
    }

    var title: String {
        if items.count == 1 { return items[0].name }
        return pluralRu(items.count, "объект", "объекта", "объектов")
    }

    var fileURLs: [URL] { items.compactMap(\.fileURL) }

    /// С чем работают действия: выделенное, а если ничего не выделено — всё.
    var targets: [PocketItem] {
        let picked = items.filter { selection.contains($0.id) }
        return picked.isEmpty ? items : picked
    }

    /// Клик выделяет один объект, с ⌘ или ⇧ — добавляет к выделению.
    func click(_ item: PocketItem, extend: Bool) {
        if extend {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = selection == [item.id] ? [] : [item.id]
        }
    }

    // MARK: Изменение

    func add(_ new: [PocketItem]) {
        let known = Set(items.map(\.kind))
        let fresh = new.filter { !known.contains($0.kind) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        onChange?()
    }

    func remove(_ ids: Set<UUID>, byDrag: Bool = false) {
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        guard items.count != before else { return }
        onChange?()
        if byDrag && items.isEmpty { onEmptiedByDrag?() }
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        selection.removeAll()
        onChange?()
    }

    /// Убирает объекты, файлы которых пропали с диска.
    func dropMissing() {
        let missing = Set(items.filter { !$0.exists }.map(\.id))
        if !missing.isEmpty { remove(missing) }
    }

    func showToast(_ text: String, symbol: String) {
        toastWork?.cancel()
        toast = (text, symbol)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: Приём из буфера обмена или перетаскивания

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Забирает всё полезное из буфера. Возвращает false, если брать нечего.
    @discardableResult
    func ingest(from pb: NSPasteboard, then action: PocketAction? = nil) -> Bool {
        // С действием объекты не ложатся в карман, а сразу обрабатываются.
        let deliver: ([PocketItem]) -> Void = { [weak self] items in
            guard let self else { return }
            if let action { self.perform(action, on: items) } else { self.add(items) }
        }
        // 1. Обычные файлы и папки.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            deliver(urls.map { PocketItem(kind: .file($0), owned: Storage.isOwned($0)) })
            return true
        }

        // 2. Файлы, которые ещё нужно получить: миниатюра скриншота, вложения, картинки из браузера.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: Storage.newItemFolder(), options: [:],
                                              operationQueue: Self.promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { deliver([PocketItem(kind: .file(url), owned: true)]) }
                }
            }
            return true
        }

        // 3. Картинка без файла. Сначала исходные данные: так GIF остаётся
        // анимированным, а JPEG не раздувается до PNG.
        for (type, ext) in Self.rawImageTypes {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(type)),
               let url = Storage.save(data: data, name: "\(Storage.imageName()).\(ext)") {
                deliver([PocketItem(kind: .file(url), owned: true)])
                return true
            }
        }

        // 4. Ссылка прямо на картинку, например GIF из браузера: скачиваем сам файл.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let images = urls.filter { !$0.isFileURL && Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty {
                for url in images { Self.download(url) { deliver([$0]) } }
                return true
            }
        }

        // 5. Любая другая картинка, например скопированная из Превью.
        if pb.canReadItem(withDataConformingToTypes: NSImage.imageTypes),
           let image = NSImage(pasteboard: pb), let url = Storage.save(image: image) {
            deliver([PocketItem(kind: .file(url), owned: true)])
            return true
        }

        // 6. Ссылки.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let links = urls.filter { $0.scheme != nil && !$0.isFileURL }
            if !links.isEmpty {
                deliver(links.map { PocketItem(kind: .link($0)) })
                return true
            }
        }

        // 7. Текст: ссылку узнаём, остальное сохраняем в .txt.
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if !text.contains(where: \.isWhitespace), let url = URL(string: text),
               let scheme = url.scheme, ["http", "https"].contains(scheme) {
                deliver([PocketItem(kind: .link(url))])
            } else if let url = Storage.save(text: text) {
                deliver([PocketItem(kind: .file(url), owned: true)])
            }
            return true
        }
        return false
    }

    private static let rawImageTypes: [(String, String)] = [
        ("com.compuserve.gif", "gif"), ("org.webmproject.webp", "webp"),
        ("public.jpeg", "jpg"), ("public.png", "png"), ("public.heic", "heic"),
    ]

    private static let imageExtensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]

    /// Скачивает картинку по ссылке в папку приложения.
    private static func download(_ url: URL, completion: @escaping (PocketItem) -> Void) {
        URLSession.shared.downloadTask(with: url) { temp, response, _ in
            guard let temp, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return }
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let target = Storage.newItemFolder().appendingPathComponent(name)
            guard (try? FileManager.default.moveItem(at: temp, to: target)) != nil else { return }
            DispatchQueue.main.async { completion(PocketItem(kind: .file(target), owned: true)) }
        }.resume()
    }

    // MARK: Действия

    func copyToPasteboard(_ subset: [PocketItem]? = nil) {
        let list = subset ?? targets
        guard !list.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(list.map(\.pasteboardWriter))
    }

    func open(_ subset: [PocketItem]? = nil) {
        for item in subset ?? items {
            switch item.kind {
            case .file(let url), .link(let url): NSWorkspace.shared.open(url)
            }
        }
    }

    func copyPaths() {
        let paths = fileURLs.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        showToast(paths.count == 1 ? "Путь скопирован" : "Пути скопированы", symbol: "checkmark.circle.fill")
    }

    func airDrop() {
        let objects: [Any] = targets.compactMap(\.fileURL)
        guard !objects.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { NSSound.beep(); return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: objects)
    }

    func revealInFinder() {
        let urls = fileURLs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Копирует всё в выбранную папку, не затирая существующие файлы.
    func copy(to folder: URL) {
        let fm = FileManager.default
        for item in items {
            switch item.kind {
            case .file(let url):
                try? fm.copyItem(at: url, to: Self.uniqueURL(in: folder, name: url.lastPathComponent))
            case .link(let url):
                let plist = ["URL": url.absoluteString]
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    try? data.write(to: Self.uniqueURL(in: folder, name: "\(item.name).webloc"))
                }
            }
        }
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = folder.appendingPathComponent(next)
            n += 1
        }
        return url
    }
}
