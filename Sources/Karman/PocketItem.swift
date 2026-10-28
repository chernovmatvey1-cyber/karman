import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Один объект в кармане: файл, ссылка или кусок текста.
/// Картинки и текст без файла сохраняются в папку приложения, чтобы их
/// можно было перетащить куда угодно как обычный файл.
final class PocketItem: Identifiable, ObservableObject {
    enum Kind: Codable, Hashable {
        case file(URL)
        case link(URL)
    }

    let id: UUID
    let kind: Kind
    /// Файл создан самим приложением и удаляется вместе с объектом.
    let owned: Bool
    @Published var thumbnail: NSImage

    init(id: UUID = UUID(), kind: Kind, owned: Bool = false) {
        self.id = id
        self.kind = kind
        self.owned = owned
        switch kind {
        case .file(let url): thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        case .link: thumbnail = PocketItem.linkIcon
        }
        loadThumbnail()
    }

    var fileURL: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    var isGIF: Bool { fileURL?.pathExtension.lowercased() == "gif" }

    var exists: Bool {
        guard let url = fileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var name: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .link(let url): return url.host ?? url.absoluteString
        }
    }

    var subtitle: String {
        switch kind {
        case .link(let url):
            return url.absoluteString
        case .file(let url):
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .localizedTypeDescriptionKey])
            if values?.isDirectory == true { return "Папка" }
            let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Что отдаётся при перетаскивании наружу.
    var pasteboardWriter: NSPasteboardWriting {
        switch kind {
        case .file(let url): return url as NSURL
        case .link(let url): return url as NSURL
        }
    }

    private static var linkIcon: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(paletteColors: [.white, .systemBlue]))
        return NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private func loadThumbnail() {
        guard let url = fileURL else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnail = image }
        }
    }
}

// MARK: Сохранение

extension PocketItem {
    struct Record: Codable {
        var id: UUID
        var kind: Kind
        var owned: Bool
    }

    var record: Record { Record(id: id, kind: kind, owned: owned) }

    convenience init(record: Record) {
        self.init(id: record.id, kind: record.kind, owned: record.owned)
    }
}

/// Папка, где лежат картинки, тексты и файлы, полученные «обещанием»
/// (например, миниатюра свежего скриншота).
enum Storage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Karman", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var items: URL { folder("Items") }
    static var stateFile: URL { root.appendingPathComponent("shelves.json") }

    /// Новая пустая папка для одного объекта, чтобы имена не конфликтовали.
    static func newItemFolder() -> URL {
        let url = items.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isOwned(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(items.standardizedFileURL.path + "/")
    }

    /// Удаляет файл, созданный приложением, вместе с его папкой.
    static func discard(_ item: PocketItem) {
        guard item.owned, let url = item.fileURL, isOwned(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func save(image: NSImage, name: String = "Картинка") -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return save(data: png, name: "\(name) \(timestamp()).png")
    }

    static func imageName() -> String { "Картинка \(timestamp())" }

    static func save(text: String) -> URL? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Текст"
        let title = String(firstLine.prefix(40)).replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return save(data: Data(text.utf8), name: "\(title.isEmpty ? "Текст" : title).txt")
    }

    static func save(data: Data, name: String) -> URL? {
        let url = newItemFolder().appendingPathComponent(name)
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// «1 объект», «2 объекта», «5 объектов».
func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return "\(n) \(one)" }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return "\(n) \(few)" }
    return "\(n) \(many)"
}
