#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let folder = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.08, green: 0.33, blue: 0.76, alpha: 1).setFill()
background.fill()
let phone = NSBezierPath(roundedRect: NSRect(x: 280, y: 180, width: 464, height: 674), xRadius: 68, yRadius: 68)
NSColor.white.setStroke()
phone.lineWidth = 34
phone.stroke()
let notch = NSBezierPath(roundedRect: NSRect(x: 428, y: 781, width: 168, height: 20), xRadius: 10, yRadius: 10)
NSColor.white.setFill()
notch.fill()
// Three QR finder squares are instantly recognizable without encoding a pairing secret.
func finder(_ x: CGFloat, _ y: CGFloat) {
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: x, y: y, width: 116, height: 116)).fill()
    NSColor(calibratedRed: 0.08, green: 0.33, blue: 0.76, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: x + 23, y: y + 23, width: 70, height: 70)).fill()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: x + 46, y: y + 46, width: 24, height: 24)).fill()
}
finder(354, 553)
finder(552, 553)
finder(354, 355)
NSColor.white.setFill()
for (x,y) in [(552,355), (622,355), (552,425), (587,460), (622,425)] {
    NSBezierPath(rect: NSRect(x: x, y: y, width: 34, height: 34)).fill()
}
image.unlockFocus()
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(filename))
        entries.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":filename])
    }
}
let manifest: [String: Any] = ["images": entries, "info": ["author":"xcode", "version":1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
