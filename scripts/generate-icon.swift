#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift OUTPUT.icns\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("Gitacre-\(UUID().uuidString).iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in entries {
    let size = CGFloat(entry.pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: entry.pixels,
        pixelsHigh: entry.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = size * 0.035
    let tileRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: size * 0.225, yRadius: size * 0.225)
    NSColor(red: 74 / 255, green: 88 / 255, blue: 196 / 255, alpha: 1).setFill()
    tile.fill()
    NSColor.white.withAlphaComponent(0.04).setStroke()
    tile.lineWidth = max(0.5, size / 512)
    tile.stroke()

    let markRect = tileRect.insetBy(dx: tileRect.width * 0.25, dy: tileRect.height * 0.25)
        .offsetBy(dx: 0, dy: size * 0.012)
    let lineWidth = max(size < 64 ? size * 0.105 : size * 0.051, 1.7)
    let trunkX = markRect.minX + markRect.width * 0.34
    let bottom = markRect.minY + markRect.height * 0.14
    let middle = markRect.minY + markRect.height * 0.50
    let top = markRect.minY + markRect.height * 0.86
    let spurX = markRect.minX + markRect.width * (size < 64 ? 0.68 : 0.72)

    let branch = NSBezierPath()
    branch.lineWidth = lineWidth
    branch.lineCapStyle = .round
    branch.lineJoinStyle = .round
    branch.move(to: NSPoint(x: trunkX, y: bottom))
    branch.line(to: NSPoint(x: trunkX, y: top))
    branch.move(to: NSPoint(x: trunkX, y: middle))
    branch.curve(
        to: NSPoint(x: spurX, y: top),
        controlPoint1: NSPoint(x: spurX, y: middle),
        controlPoint2: NSPoint(x: spurX, y: top)
    )
    NSColor.white.setStroke()
    branch.stroke()

    let radius = lineWidth * 1.23
    for point in [NSPoint(x: trunkX, y: bottom), NSPoint(x: trunkX, y: top), NSPoint(x: spurX, y: top)] {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconsetURL.appendingPathComponent(entry.name), options: .atomic)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
