// Draws MyEmu's temporary app icon (1024×1024 PNG) and builds AppIcon.icns from it.
// Usage: swift scripts/make-icon.swift Assets
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets")
let size: CGFloat = 1024
// macOS icon grid: the rounded square sits 100 pt in from each edge, corner radius ≈ 22.5% of it.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Soft drop shadow under the tile, like system icons.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// Android green → sky blue.
let gradient = NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.77, blue: 0.37, alpha: 1),
                                   NSColor(srgbRed: 0.05, green: 0.52, blue: 0.91, alpha: 1)])!
gradient.draw(in: path, angle: -60)
// A gentle top highlight for depth.
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// White game controller glyph.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let glyph = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let glyphSize = glyph.size
let glyphRect = CGRect(x: tile.midX - glyphSize.width / 2, y: tile.midY - glyphSize.height / 2 - 10,
                       width: glyphSize.width, height: glyphSize.height)
NSGraphicsContext.saveGraphicsState()
let glyphShadow = NSShadow()
glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
glyphShadow.shadowBlurRadius = 18
glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
glyphShadow.set()
glyph.draw(in: glyphRect)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let png = outDir.appending(path: "AppIcon.png")
try rep.representation(using: .png, properties: [:])!.write(to: png)

// .iconset → .icns with every size macOS asks for.
let iconset = outDir.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-z", "\(px)", "\(px)", png.path, "--out", iconset.appending(path: name).path]
        sips.standardOutput = FileHandle.nullDevice
        try sips.run()
        sips.waitUntilExit()
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(png.path) and AppIcon.icns" : "iconutil failed")
