import AppKit
import SwiftUI

/// Окно обрезки. Если картинок несколько, они идут по очереди.
final class CropEditor: NSObject, NSWindowDelegate {
    private static var current: CropEditor?

    private let window: NSPanel
    private let model: CropModel
    private var queue: [URL]
    private var results: [URL] = []
    private let completion: ([URL]) -> Void

    static func open(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        guard !urls.isEmpty else { return }
        current?.finish()
        current = CropEditor(urls: urls, completion: completion)
    }

    private init(urls: [URL], completion: @escaping ([URL]) -> Void) {
        queue = urls
        self.completion = completion
        model = CropModel()
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        model.onDone = { [weak self] apply in self?.done(apply: apply) }
        model.onApplyToRest = { [weak self] in self?.applyToRest() }
        window.contentView = FirstClickHostingView(rootView: CropView(model: model))
        loadNext()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func loadNext() {
        guard let url = queue.first else { finish(); return }
        model.load(url, remaining: queue.count - 1)
    }

    private func done(apply: Bool) {
        guard let url = queue.first else { return }
        if apply, let out = Cropper.crop(url, to: model.rect, suffix: model.ratio.fileSuffix) {
            results.append(out)
        }
        queue.removeFirst()
        loadNext()
    }

    /// Остальные картинки обрезаются умно в той же пропорции, без ручной правки.
    private func applyToRest() {
        done(apply: true)
        let ratio = model.ratio
        results += queue.compactMap { Cropper.smartCrop($0, ratio: ratio) }
        queue.removeAll()
        finish()
    }

    private func finish() {
        let out = results
        results = []
        window.delegate = nil
        window.orderOut(nil)
        if !out.isEmpty { completion(out) }
        if Self.current === self { Self.current = nil }
    }

    func windowWillClose(_ notification: Notification) {
        queue.removeAll()
        finish()
    }
}

// MARK: Модель

final class CropModel: ObservableObject {
    @Published var image: NSImage?
    @Published var pixelSize = CGSize(width: 1, height: 1)
    /// Рамка в долях от размера картинки, начало в верхнем левом углу.
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var ratio: CropRatio = .r16x9
    @Published var remaining = 0
    @Published var name = ""
    private var focus = CGPoint(x: 0.5, y: 0.5)

    var onDone: ((Bool) -> Void)?
    var onApplyToRest: (() -> Void)?

    func load(_ url: URL, remaining: Int) {
        image = NSImage(contentsOf: url)
        pixelSize = Cropper.pixelSize(url) ?? image?.size ?? CGSize(width: 1, height: 1)
        name = url.lastPathComponent
        self.remaining = remaining
        focus = CGPoint(x: 0.5, y: 0.5)
        rect = Cropper.rect(ratio: ratio.value, imageSize: pixelSize, around: focus)
        // Главное на картинке ищется в фоне, рамка потом подъезжает к нему.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let point = Cropper.focusPoint(url)
            DispatchQueue.main.async {
                guard let self, self.name == url.lastPathComponent else { return }
                self.focus = point
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.setRatio(self.ratio) }
            }
        }
    }

    /// Новая пропорция: самая большая рамка вокруг главного. «Свободно» оставляет рамку как есть.
    func setRatio(_ r: CropRatio) {
        ratio = r
        guard r != .free else { return }
        rect = Cropper.rect(ratio: r.value, imageSize: pixelSize, around: focus)
    }

    /// Высота в долях для ширины в долях при заданной пропорции.
    func height(forWidth w: CGFloat) -> CGFloat? {
        ratio.value.map { w * pixelSize.width / (pixelSize.height * $0) }
    }

    func width(forHeight h: CGFloat) -> CGFloat? {
        ratio.value.map { h * pixelSize.height * $0 / pixelSize.width }
    }

    /// Новая рамка после того, как ручку сдвинули на (dx, dy) долей.
    func resized(_ s: CGRect, handle h: CropCanvas.Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSide: CGFloat = 0.03
        // Неподвижная сторона или угол напротив ручки.
        let ax = h.hx == 1 ? s.minX : s.maxX
        let ay = h.hy == 1 ? s.minY : s.maxY
        let availW = h.hx == 1 ? 1 - ax : ax
        let availH = h.hy == 1 ? 1 - ay : ay
        var w = h.hx == 0 ? s.width : min(max(s.width + CGFloat(h.hx) * dx, minSide), availW)
        var h2 = h.hy == 0 ? s.height : min(max(s.height + CGFloat(h.hy) * dy, minSide), availH)

        if ratio.value != nil {
            if h.hy == 0 {
                // Тянем левую или правую сторону: высота следует за шириной, по центру.
                let maxH = 2 * min(s.midY, 1 - s.midY)
                h2 = height(forWidth: w)!
                if h2 > maxH { h2 = maxH; w = width(forHeight: h2)! }
            } else if h.hx == 0 {
                let maxW = 2 * min(s.midX, 1 - s.midX)
                w = width(forHeight: h2)!
                if w > maxW { w = maxW; h2 = height(forWidth: w)! }
            } else {
                h2 = height(forWidth: w)!
                if h2 > availH { h2 = availH; w = width(forHeight: h2)! }
            }
        }

        let x: CGFloat = h.hx == 0 ? s.midX - w / 2 : (h.hx == 1 ? ax : ax - w)
        let y: CGFloat = h.hy == 0 ? s.midY - h2 / 2 : (h.hy == 1 ? ay : ay - h2)
        return CGRect(x: x, y: y, width: w, height: h2)
    }

    var pixelLabel: String {
        "\(Int((rect.width * pixelSize.width).rounded())) × \(Int((rect.height * pixelSize.height).rounded()))"
    }
}

// MARK: Интерфейс

struct CropView: View {
    @ObservedObject var model: CropModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(model.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(model.pixelLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 18)

            CropCanvas(model: model)

            HStack(spacing: 6) {
                ForEach(CropRatio.allCases, id: \.self) { r in
                    let on = model.ratio == r
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.setRatio(r) }
                    } label: {
                        HStack(spacing: 5) {
                            if let v = r.value { RatioGlyph(ratio: v) }
                            Text(r.title)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(on ? Color.accentColor : .white.opacity(0.08)))
                        .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                if model.remaining > 0 {
                    Button("Так же для остальных (\(model.remaining))") { model.onApplyToRest?() }
                        .help("Обрезать остальные картинки умно в той же пропорции")
                }
                Spacer()
                Button(model.remaining > 0 ? "Пропустить" : "Отмена") { model.onDone?(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Обрезать") { model.onDone?(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding([.horizontal, .bottom], 18)
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(white: 0.11))
    }
}

/// Маленький прямоугольник нужной пропорции на кнопке.
struct RatioGlyph: View {
    let ratio: CGFloat
    var body: some View {
        let w: CGFloat = ratio >= 1 ? 14 : 14 * ratio
        let h: CGFloat = ratio >= 1 ? 14 / ratio : 14
        RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.5).frame(width: w, height: h)
    }
}

/// Клик по окну сразу работает, даже если окно было неактивным.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Холст обрезки. Одно касание решает, что тянем: угол, сторону, рамку целиком
/// или новую рамку по пустому месту.
struct CropCanvas: View {
    @ObservedObject var model: CropModel
    @State private var drag: Drag?

    /// Ручка: куда она смотрит по горизонтали и вертикали (-1, 0, 1).
    struct Handle: Hashable {
        let hx: Int, hy: Int
        static let all: [Handle] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
            .map { Handle(hx: $0.0, hy: $0.1) }
        var isCorner: Bool { hx != 0 && hy != 0 }
    }

    private enum Drag {
        case move(CGRect)
        case resize(Handle, CGRect)
        case create(CGPoint)
    }

    var body: some View {
        GeometryReader { geo in
            let frame = fitted(in: geo.size)
            let r = display(model.rect, in: frame)
            ZStack(alignment: .topLeading) {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                // Всё вне рамки затемнено.
                Path { p in
                    p.addRect(frame)
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

                // Сетка третей и рамка.
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        let y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                Path { $0.addRect(r) }
                    .stroke(.white, lineWidth: 1.5)

                ForEach(Handle.all, id: \.self) { h in
                    let p = point(h, of: r)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .frame(width: h.isCorner ? 14 : (h.hx == 0 ? 26 : 6),
                               height: h.isCorner ? 14 : (h.hy == 0 ? 26 : 6))
                        .position(p)
                }

                // Один слой поверх всего ловит мышь.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(frame: frame))
                    .onContinuousHover { phase in
                        guard drag == nil else { return }
                        if case .active(let p) = phase { cursor(at: p, frame: frame).set() } else { NSCursor.arrow.set() }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Геометрия

    private func fitted(in size: CGSize) -> CGRect {
        let px = model.pixelSize
        let scale = min(size.width / px.width, size.height / px.height)
        let w = px.width * scale, h = px.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func display(_ n: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + n.minX * frame.width, y: frame.minY + n.minY * frame.height,
               width: n.width * frame.width, height: n.height * frame.height)
    }

    private func point(_ h: Handle, of r: CGRect) -> CGPoint {
        CGPoint(x: r.midX + CGFloat(h.hx) * r.width / 2, y: r.midY + CGFloat(h.hy) * r.height / 2)
    }

    private func handle(at p: CGPoint, frame: CGRect) -> Handle? {
        let r = display(model.rect, in: frame)
        // Углы важнее сторон.
        return Handle.all.sorted { $0.isCorner && !$1.isCorner }
            .first { h in
                let c = point(h, of: r)
                return abs(c.x - p.x) <= 12 && abs(c.y - p.y) <= 12
            }
    }

    private func cursor(at p: CGPoint, frame: CGRect) -> NSCursor {
        if let h = handle(at: p, frame: frame) {
            if h.isCorner { return .crosshair }
            return h.hx == 0 ? .resizeUpDown : .resizeLeftRight
        }
        if display(model.rect, in: frame).contains(p) { return .openHand }
        return frame.contains(p) ? .crosshair : .arrow
    }

    // MARK: Перетаскивание

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    if let h = handle(at: g.startLocation, frame: frame) {
                        drag = .resize(h, model.rect)
                    } else if display(model.rect, in: frame).contains(g.startLocation) {
                        drag = .move(model.rect)
                        NSCursor.closedHand.set()
                    } else if frame.contains(g.startLocation) {
                        drag = .create(normalized(g.startLocation, frame: frame))
                    } else {
                        return
                    }
                }
                let dx = g.translation.width / frame.width
                let dy = g.translation.height / frame.height
                switch drag! {
                case .move(let start):
                    model.rect.origin = CGPoint(x: min(max(start.minX + dx, 0), 1 - start.width),
                                                y: min(max(start.minY + dy, 0), 1 - start.height))
                case .resize(let h, let start):
                    model.rect = model.resized(start, handle: h, dx: dx, dy: dy)
                case .create(let p0):
                    let p1 = normalized(g.location, frame: frame)
                    // Новая рамка — это растягивание угла из точки нажатия.
                    let h = Handle(hx: p1.x >= p0.x ? 1 : -1, hy: p1.y >= p0.y ? 1 : -1)
                    let seed = CGRect(x: p0.x, y: p0.y, width: 0, height: 0)
                    model.rect = model.resized(seed, handle: h, dx: p1.x - p0.x, dy: p1.y - p0.y)
                }
            }
            .onEnded { _ in
                drag = nil
                NSCursor.arrow.set()
            }
    }

    private func normalized(_ p: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - frame.minX) / frame.width, 0), 1),
                y: min(max((p.y - frame.minY) / frame.height, 0), 1))
    }

}
