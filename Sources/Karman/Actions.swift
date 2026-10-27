import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Что полка умеет делать с объектами. Всё считается на самом Mac, без сети.
enum ShelfAction: CaseIterable {
    case text, cutout, wide, crop, compress, pdf, zip

    /// Плитки, которые появляются, пока над полкой что-то несут.
    static let instant: [ShelfAction] = [.text, .cutout, .wide, .compress]
    /// Кнопки внизу раскрытой полки. PDF, ZIP и AirDrop живут в меню ⌄.
    static let bar: [ShelfAction] = [.text, .cutout, .wide, .crop, .compress]

    var title: String {
        switch self {
        case .text: return "Текст"
        case .cutout: return "Без фона"
        case .wide: return "16:9"
        case .crop: return "Обрезать"
        case .compress: return "Сжать"
        case .pdf: return "PDF"
        case .zip: return "ZIP"
        }
    }

    var menuTitle: String {
        switch self {
        case .text: return "Распознать текст"
        case .cutout: return "Вырезать фон"
        case .wide: return "Умная обрезка 16:9"
        case .crop: return "Обрезать…"
        case .compress: return "Сжать картинки"
        case .pdf: return "Собрать картинки в PDF"
        case .zip: return "Упаковать в ZIP"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.viewfinder"
        case .cutout: return "person.crop.rectangle.badge.plus"
        case .wide: return "rectangle.ratio.16.to.9"
        case .crop: return "crop"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .pdf: return "doc.richtext"
        case .zip: return "doc.zipper"
        }
    }

    var needsImages: Bool { self != .zip }
}

extension Shelf {
    /// Выполняет действие и кладёт результат на полку.
    func perform(_ action: ShelfAction, on items: [ShelfItem]) {
        let urls = items.compactMap(\.fileURL)
        var input = action.needsImages ? urls.filter(Processing.isImage) : urls
        // GIF при сжатии потерял бы анимацию.
        if action == .compress { input.removeAll { $0.pathExtension.lowercased() == "gif" } }
        guard !input.isEmpty else {
            NSSound.beep()
            let onlyGIF = action == .compress && urls.contains { $0.pathExtension.lowercased() == "gif" }
            showToast(onlyGIF ? "GIF не сжимаю — пропадёт анимация"
                      : action.needsImages ? "Нужна картинка" : "Нечего упаковать",
                      symbol: "exclamationmark.circle")
            return
        }
        if action == .crop {
            // Обрезка вручную открывает редактор, результат возвращается на полку.
            CropEditor.open(input) { [weak self] urls in
                self?.add(urls.map { ShelfItem(kind: .file($0), owned: true) })
            }
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [URL] = []
            var toast: (String, String)?
            switch action {
            case .text:
                let text = input.compactMap(Processing.recognizeText).joined(separator: "\n\n")
                if text.isEmpty {
                    toast = ("Текст не найден", "exclamationmark.circle")
                } else {
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    if let url = Storage.save(text: text) { results.append(url) }
                    toast = ("Текст скопирован", "checkmark.circle.fill")
                }
            case .cutout:
                results = input.compactMap(Processing.removeBackground)
                toast = results.isEmpty ? ("Не нашёл объект", "exclamationmark.circle") : ("Фон убран", "checkmark.circle.fill")
            case .wide:
                results = input.compactMap { Cropper.smartCrop($0, ratio: .r16x9) }
                toast = results.isEmpty ? ("Не получилось", "exclamationmark.circle") : ("Обрезано в 16:9", "checkmark.circle.fill")
            case .crop:
                break
            case .compress:
                results = input.compactMap(Processing.compress)
                let before = input.map(Processing.size).reduce(0, +)
                let after = results.map(Processing.size).reduce(0, +)
                if after > 0 {
                    let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                    toast = ("\(f(before)) → \(f(after))", "checkmark.circle.fill")
                }
            case .pdf:
                if let url = Processing.makePDF(input) { results.append(url) }
                toast = results.isEmpty ? ("Не получилось", "exclamationmark.circle") : ("PDF готов", "checkmark.circle.fill")
            case .zip:
                if let url = Processing.zip(input) { results.append(url) }
                toast = results.isEmpty ? ("Не получилось", "exclamationmark.circle") : ("Архив готов", "checkmark.circle.fill")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.add(results.map { ShelfItem(kind: .file($0), owned: true) })
                if let toast { self.showToast(toast.0, symbol: toast.1) }
            }
        }
    }
}

enum Processing {
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func base(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Распознаёт русский и английский текст на картинке.
    static func recognizeText(_ url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        do {
            try VNImageRequestHandler(url: url).perform([request])
        } catch { return nil }
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Вырезает главный объект с картинки и сохраняет его PNG с прозрачным фоном.
    static func removeBackground(_ url: URL) -> URL? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: url)
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
            let out = Storage.newItemFolder().appendingPathComponent("\(base(url)) (без фона).png")
            try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: out, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return out
        } catch { return nil }
    }

    /// Уменьшает до 2048 px по длинной стороне и пересохраняет в JPEG.
    static func compress(_ url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = Storage.newItemFolder().appendingPathComponent("\(base(url)) (сжато).jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    /// Складывает картинки в один PDF, по странице на каждую.
    static func makePDF(_ urls: [URL]) -> URL? {
        let doc = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { return nil }
        let name = urls.count == 1 ? base(urls[0]) : "Картинки (\(urls.count) стр.)"
        let out = Storage.newItemFolder().appendingPathComponent("\(name).pdf")
        return doc.write(to: out) ? out : nil
    }

    /// Упаковывает файлы и папки в ZIP средствами системы.
    static func zip(_ urls: [URL]) -> URL? {
        let folder = Storage.newItemFolder()
        let fm = FileManager.default
        if urls.count == 1 {
            let out = folder.appendingPathComponent("\(urls[0].lastPathComponent).zip")
            return ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path]) ? out : nil
        }
        // Несколько объектов из разных мест: сначала собираем их вместе.
        // На APFS копия мгновенная и не занимает места.
        let staging = fm.temporaryDirectory.appendingPathComponent("Karman-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for url in urls {
                var target = staging.appendingPathComponent(url.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = staging.appendingPathComponent("\(base(url)) \(n).\(url.pathExtension)")
                    n += 1
                }
                try fm.copyItem(at: url, to: target)
            }
        } catch { return nil }
        let out = folder.appendingPathComponent("Архив (\(pluralRu(urls.count, "файл", "файла", "файлов"))).zip")
        return ditto(["-c", "-k", "--sequesterRsrc", staging.path, out.path]) ? out : nil
    }

    private static func ditto(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
