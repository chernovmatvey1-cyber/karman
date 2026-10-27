import AppKit
import SwiftUI

protocol ShelfActions: AnyObject {
    func closeShelf()
    func showMenu()
    func remove(_ item: ShelfItem)
    func toggleExpanded()
    func run(_ action: ShelfAction)
}

/// Размеры, общие для SwiftUI и для расчёта зон в AppKit.
enum ShelfLayout {
    static let compact = NSSize(width: 206, height: 208)
    static let expanded = NSSize(width: 320, height: 396)
    static let radius: CGFloat = 22
    static let inset: CGFloat = 10
    static let tilesHeight: CGFloat = 56
    static let tileSpacing: CGFloat = 6

    /// Номер плитки под точкой (координаты окна, начало снизу) или nil.
    static func tile(at p: NSPoint, width: CGFloat) -> Int? {
        guard p.y <= inset + tilesHeight + 2, p.y >= 0 else { return nil }
        let count = CGFloat(ShelfAction.instant.count)
        let step = (width - inset * 2 + tileSpacing) / count
        let i = Int((p.x - inset) / step)
        return (0..<ShelfAction.instant.count).contains(i) ? i : nil
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    let actions: ShelfActions

    private var showsChrome: Bool { shelf.hovering && !shelf.isTargeted && !shelf.busy }

    var body: some View {
        ZStack {
            Color(white: 0.42).opacity(0.5)

            Group {
                if shelf.isTargeted {
                    DropTargets(shelf: shelf)
                } else if shelf.items.isEmpty {
                    Text("Перетащите сюда")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                } else if shelf.expanded {
                    VStack(spacing: 0) {
                        ItemGrid(shelf: shelf, actions: actions)
                        ActionBar(shelf: shelf, actions: actions)
                    }
                } else {
                    Pile(shelf: shelf, actions: actions)
                }
            }
            .transition(.opacity)

            VStack {
                HStack(spacing: 6) {
                    RoundButton(symbol: "xmark", help: "Закрыть полку") { actions.closeShelf() }
                    if shelf.expanded {
                        RoundButton(symbol: "chevron.backward", help: "Свернуть в стопку") { actions.toggleExpanded() }
                    }
                    Spacer()
                    if shelf.expanded {
                        Text(shelf.selection.isEmpty ? shelf.title
                             : "Выбрано: \(shelf.selection.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                        Spacer()
                    }
                    RoundButton(symbol: "chevron.down", help: "Ещё действия") { actions.showMenu() }
                }
                .background(WindowDragArea())
                Spacer()
            }
            .padding(10)
            .opacity(showsChrome || (shelf.expanded && !shelf.isTargeted) ? 1 : 0)

            if shelf.busy {
                ProgressView()
                    .controlSize(.small)
                    .padding(14)
                    .background(Circle().fill(.black.opacity(0.35)))
            }

            if let toast = shelf.toast {
                VStack {
                    Spacer()
                    Label(toast.text, systemImage: toast.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.bottom, shelf.expanded ? 64 : 12)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ShelfLayout.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShelfLayout.radius, style: .continuous)
                .strokeBorder(.white.opacity(shelf.isTargeted ? 0.35 : 0.1), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: showsChrome)
        .animation(.easeOut(duration: 0.18), value: shelf.isTargeted)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shelf.toast?.text)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Пока над полкой несут объекты

struct DropTargets: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(shelf.dropAction == nil ? 0.13 : 0.04))
                .overlay(
                    Text("На полку")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(shelf.dropAction == nil ? 0.85 : 0.35))
                )
            HStack(spacing: ShelfLayout.tileSpacing) {
                ForEach(ShelfAction.instant, id: \.self) { action in
                    let active = shelf.dropAction == action
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 14, weight: .medium))
                        Text(action.title)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.85) : .white.opacity(0.08))
                    )
                    .scaleEffect(active ? 1.06 : 1)
                }
            }
            .frame(height: ShelfLayout.tilesHeight)
        }
        .padding(ShelfLayout.inset)
        .animation(.easeOut(duration: 0.12), value: shelf.dropAction)
    }
}

// MARK: Кнопка-кружок

struct RoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.3 : 0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: Стопка

struct Pile: View {
    @ObservedObject var shelf: Shelf
    let actions: ShelfActions
    private let angles: [Double] = [-8, 6, 0]

    var body: some View {
        let shown = Array(shelf.items.suffix(3))
        VStack(spacing: 12) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let fromTop = shown.count - 1 - index
                    Thumb(item: item, side: 92, animate: fromTop == 0)
                        .rotationEffect(.degrees(shown.count == 1 ? 0 : angles[max(0, 2 - fromTop)]))
                        .offset(x: CGFloat(fromTop) * -4, y: CGFloat(fromTop) * -3)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 150, height: 108)
            .overlay(DragSource(shelf: shelf, items: { shelf.items },
                                onClick: { _ in actions.toggleExpanded() }))

            Text(shelf.hovering ? "Показать все" : shelf.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.16)))
                .frame(maxWidth: 170)
                .opacity(shelf.toast == nil ? 1 : 0)
        }
        .padding(.top, 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: shelf.items.map(\.id))
    }
}

struct Thumb: View {
    @ObservedObject var item: ShelfItem
    let side: CGFloat
    var animate = true

    var body: some View {
        Group {
            if animate, item.isGIF, let url = item.fileURL {
                AnimatedImage(url: url)
                    .frame(width: side, height: side)
            } else {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
            .frame(maxWidth: side, maxHeight: side)
            .clipShape(RoundedRectangle(cornerRadius: side > 50 ? 6 : 4, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: side > 50 ? 5 : 2, y: 2)
    }
}

// MARK: Все объекты сеткой

struct ItemGrid: View {
    @ObservedObject var shelf: Shelf
    let actions: ShelfActions
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(shelf.items.reversed()) { item in
                    GridCell(shelf: shelf, item: item, actions: actions)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .padding(.top, 40)
        .padding(.horizontal, 10)
    }
}

struct GridCell: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var item: ShelfItem
    let actions: ShelfActions
    @State private var hover = false

    private var selected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 5) {
            Thumb(item: item, side: 60)
                .frame(width: 64, height: 64)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.55) : .white.opacity(hover ? 0.08 : 0))
        )
        .overlay(DragSource(shelf: shelf,
                            // Тянешь выделенный — уезжает всё выделенное.
                            items: { selected ? shelf.targets : [item] },
                            onDoubleClick: { shelf.open([item]) },
                            onClick: { extend in shelf.click(item, extend: extend) }))
        .overlay(alignment: .topTrailing) {
            Button { actions.remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help("Убрать с полки")
            .offset(x: 2, y: -2)
        }
        .onHover { hover = $0 }
        .help(item.name)
    }
}

/// Функции полки, всегда на виду в раскрытом виде.
struct ActionBar: View {
    @ObservedObject var shelf: Shelf
    let actions: ShelfActions

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ShelfAction.bar, id: \.self) { action in
                BarButton(symbol: action.symbol, title: action.title, help: action.menuTitle) {
                    actions.run(action)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
    }
}

struct BarButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 16)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hover ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: Мосты в AppKit

struct DragSource: NSViewRepresentable {
    let shelf: Shelf
    let items: () -> [ShelfItem]
    var onDoubleClick: (() -> Void)?
    var onClick: ((Bool) -> Void)?

    func makeNSView(context: Context) -> ItemDragView {
        let view = ItemDragView()
        update(view)
        return view
    }

    func updateNSView(_ view: ItemDragView, context: Context) { update(view) }

    private func update(_ view: ItemDragView) {
        view.shelf = shelf
        view.items = items
        view.onDoubleClick = onDoubleClick
        view.onClick = onClick
    }
}

/// Полосу кнопок можно тянуть, чтобы передвинуть полку.
struct WindowDragArea: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

/// Анимированное превью GIF.
struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
