// Рисует иконку «Кармана»: стеклянный карман со строчкой и стрелкой внутрь.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    // Фон: скруглённый квадрат macOS с диагональным градиентом.
    let inset: CGFloat = 100
    let bg = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.98, alpha: 1),
                        NSColor(red: 0.13, green: 0.72, blue: 0.98, alpha: 1)])!
        .draw(in: bg, angle: -50)
    // Блик сверху.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: bg.minX, y: bg.midY, width: bg.width, height: bg.height / 2), angle: -90)

    // Карман: прямоугольник со скруглённым низом.
    let pocket = NSRect(x: 290, y: 230, width: 444, height: 380)
    let path = NSBezierPath()
    let r: CGFloat = 150
    path.move(to: NSPoint(x: pocket.minX, y: pocket.maxY))
    path.line(to: NSPoint(x: pocket.minX, y: pocket.minY + r))
    path.appendArc(withCenter: NSPoint(x: pocket.midX, y: pocket.minY + r), radius: pocket.width / 2,
                   startAngle: 180, endAngle: 360, clockwise: false)
    path.line(to: NSPoint(x: pocket.maxX, y: pocket.maxY))
    path.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.withAlphaComponent(0.95).setFill(); path.fill()
    ctx.restoreGState()

    // Строчка по краю кармана.
    let stitch = NSBezierPath()
    let s: CGFloat = 34
    stitch.move(to: NSPoint(x: pocket.minX + s, y: pocket.maxY - s))
    stitch.line(to: NSPoint(x: pocket.minX + s, y: pocket.minY + r))
    stitch.appendArc(withCenter: NSPoint(x: pocket.midX, y: pocket.minY + r), radius: pocket.width / 2 - s,
                     startAngle: 180, endAngle: 360, clockwise: false)
    stitch.line(to: NSPoint(x: pocket.maxX - s, y: pocket.maxY - s))
    stitch.close()
    stitch.lineWidth = 12
    stitch.setLineDash([30, 22], count: 2, phase: 0)
    stitch.lineCapStyle = .round
    NSColor(red: 0.30, green: 0.40, blue: 0.95, alpha: 0.45).setStroke(); stitch.stroke()

    // Стрелка, уходящая в карман.
    let arrow = NSBezierPath()
    arrow.lineWidth = 58
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 512, y: 800)); arrow.line(to: NSPoint(x: 512, y: 470))
    arrow.move(to: NSPoint(x: 412, y: 565)); arrow.line(to: NSPoint(x: 512, y: 465)); arrow.line(to: NSPoint(x: 612, y: 565))
    NSColor(red: 0.25, green: 0.35, blue: 0.97, alpha: 1).setStroke(); arrow.stroke()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
