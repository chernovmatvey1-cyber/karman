import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Пропорции для обрезки.
enum CropRatio: CaseIterable, Hashable {
    case r16x9, r9x16, r4x3, r1x1, r3x2, free

    var title: String {
        switch self {
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r3x2: return "3:2"
        case .free: return "Свободно"
        }
    }

    /// Ширина к высоте; nil — без ограничений.
    var value: CGFloat? {
        switch self {
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        case .r4x3: return 4.0 / 3
        case .r1x1: return 1
        case .r3x2: return 3.0 / 2
        case .free: return nil
        }
    }

    var fileSuffix: String { self == .free ? "обрезка" : title.replacingOccurrences(of: ":", with: "x") }
}

enum Cropper {
    /// Размер картинки в пикселях с учётом поворота.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Центр самого важного на картинке (лица, объекты, текст), в долях 0…1 от верхнего левого угла.
    static func focusPoint(_ url: URL) -> CGPoint {
        // Сначала ищем предметы, если их нет — то, куда посмотрит человек.
        let requests: [VNImageBasedRequest] = [VNGenerateObjectnessBasedSaliencyImageRequest(),
                                               VNGenerateAttentionBasedSaliencyImageRequest()]
        for request in requests {
            guard (try? VNImageRequestHandler(url: url).perform([request])) != nil,
                  let observation = request.results?.first as? VNSaliencyImageObservation,
                  let objects = observation.salientObjects, !objects.isEmpty else { continue }
            let boxes = objects.sorted { $0.confidence > $1.confidence }.prefix(3).map(\.boundingBox)
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            // У Vision начало координат внизу.
            return CGPoint(x: union.midX, y: 1 - union.midY)
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    /// Самая большая рамка нужной пропорции с центром как можно ближе к точке.
    static func rect(ratio: CGFloat?, imageSize size: CGSize, around focus: CGPoint) -> CGRect {
        guard let ratio else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var w: CGFloat = 1
        var h = w * size.width / (size.height * ratio)
        if h > 1 { h = 1; w = h * size.height * ratio / size.width }
        let x = min(max(focus.x - w / 2, 0), 1 - w)
        let y = min(max(focus.y - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Умная обрезка без вопросов: например, сразу в 16:9 вокруг главного.
    static func smartCrop(_ url: URL, ratio: CropRatio) -> URL? {
        guard let size = pixelSize(url) else { return nil }
        let r = rect(ratio: ratio.value, imageSize: size, around: focusPoint(url))
        return crop(url, to: r, suffix: ratio.fileSuffix)
    }

    /// Обрезает по рамке в долях. GIF обрезается покадрово и остаётся анимированным.
    static func crop(_ url: URL, to r: CGRect, suffix: String) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let size = pixelSize(url) else { return nil }
        let px = CGRect(x: (r.minX * size.width).rounded(), y: (r.minY * size.height).rounded(),
                        width: max(1, (r.width * size.width).rounded()), height: max(1, (r.height * size.height).rounded()))
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let isGIF = ext == "gif"
        let keepExt = ["png", "jpg", "jpeg", "heic", "gif"].contains(ext) ? ext : "png"
        let out = Storage.newItemFolder().appendingPathComponent("\(base) (\(suffix)).\(keepExt)")
        let type: UTType = isGIF ? .gif : (UTType(filenameExtension: keepExt) ?? .png)
        let frames = isGIF ? CGImageSourceGetCount(src) : 1

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, frames, nil) else { return nil }
        if isGIF, let props = CGImageSourceCopyProperties(src, nil) {
            CGImageDestinationSetProperties(dest, props)
        }
        for i in 0..<frames {
            guard let image = orientedImage(src, index: i), let cropped = image.cropping(to: px) else { return nil }
            let props = isGIF ? CGImageSourceCopyPropertiesAtIndex(src, i, nil) : nil
            CGImageDestinationAddImage(dest, cropped, props)
        }
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    /// Кадр в правильной ориентации и полном размере.
    private static func orientedImage(_ src: CGImageSource, index: Int) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              (props[kCGImagePropertyOrientation] as? UInt32 ?? 1) != 1 else {
            return CGImageSourceCreateImageAtIndex(src, index, nil)
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }
}
