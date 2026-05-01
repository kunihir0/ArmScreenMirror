import AppKit

// 1024x1024 master icon. Two-tone gradient background, white iPhone
// silhouette in the centre, three broadcast arcs above it, and a small
// "live" status dot offset to the top-right of the icon. Distinctive
// against typical Dock contents.
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// --- Background: rounded square + indigo→cyan gradient.
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                          xRadius: 180, yRadius: 180)
ctx.saveGState()
bgPath.addClip()
let cs = CGColorSpaceCreateDeviceRGB()
let bgColors: [CGColor] = [
    NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.36, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.92, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.86, alpha: 1).cgColor,
]
let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: NSPoint(x: 0, y: size.height),
                       end:   NSPoint(x: size.width, y: 0),
                       options: [])

// Subtle inner highlight at the top-left for depth.
let highlight = CGGradient(colorsSpace: cs, colors: [
    NSColor.white.withAlphaComponent(0.25).cgColor,
    NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(highlight,
                       startCenter: NSPoint(x: 280, y: 820), startRadius: 0,
                       endCenter:   NSPoint(x: 280, y: 820), endRadius: 700,
                       options: [])
ctx.restoreGState()

// --- iPhone silhouette (white).
let phoneRect = NSRect(x: 312, y: 180, width: 400, height: 660)
let phonePath = NSBezierPath(roundedRect: phoneRect, xRadius: 70, yRadius: 70)
ctx.saveGState()
// Drop shadow for the phone.
ctx.setShadow(offset: CGSize(width: 0, height: -16),
              blur: 36,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.white.setFill()
phonePath.fill()
ctx.restoreGState()

// --- iPhone screen (dark glass).
let screenRect = phoneRect.insetBy(dx: 22, dy: 78)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 46, yRadius: 46)
NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.18, alpha: 1).setFill()
screenPath.fill()

// Notch (small pill at the top of the screen).
let notchRect = NSRect(x: phoneRect.midX - 80,
                       y: screenRect.maxY - 28,
                       width: 160,
                       height: 22)
let notchPath = NSBezierPath(roundedRect: notchRect, xRadius: 11, yRadius: 11)
NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
notchPath.fill()

// --- Broadcast arcs inside the screen, suggesting "mirroring".
let cx = phoneRect.midX
let cy = phoneRect.midY - 30
ctx.saveGState()
screenPath.addClip()
let arcColors: [CGColor] = [
    NSColor(calibratedRed: 0.22, green: 0.86, blue: 1.00, alpha: 0.95).cgColor,
    NSColor(calibratedRed: 0.55, green: 0.50, blue: 1.00, alpha: 0.95).cgColor,
]
for (i, r) in stride(from: 90.0, through: 230.0, by: 70.0).enumerated() {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: cx, y: cy - 40),
                  radius: CGFloat(r),
                  startAngle: 35,
                  endAngle: 145)
    arc.lineWidth = 18
    arc.lineCapStyle = .round
    let c = (i % 2 == 0) ? arcColors[0] : arcColors[1]
    NSColor(cgColor: c)?.setStroke()
    arc.stroke()
}

// Solid dot at the apex (signal source / "play").
NSColor(calibratedRed: 0.22, green: 0.86, blue: 1.00, alpha: 1).setFill()
let dotR: CGFloat = 32
NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - 40 - dotR,
                            width: dotR * 2, height: dotR * 2)).fill()
ctx.restoreGState()

// --- "Live" status badge in the top-right of the canvas.
let badgeR: CGFloat = 70
let badgeRect = NSRect(x: size.width - 70 - badgeR * 2 + 30,
                       y: size.height - 70 - badgeR * 2 + 30,
                       width: badgeR * 2,
                       height: badgeR * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6),
              blur: 18,
              color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSColor.white.setFill()
NSBezierPath(ovalIn: badgeRect).fill()
ctx.restoreGState()
NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
NSBezierPath(ovalIn: badgeRect.insetBy(dx: 18, dy: 18)).fill()

img.unlockFocus()

// --- Write PNG.
let outPath = CommandLine.arguments.dropFirst().first ?? "/tmp/icon_1024.png"
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count) bytes)")
