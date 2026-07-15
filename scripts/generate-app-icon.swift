#!/usr/bin/env swift

import AppKit
import Foundation

guard let rawOutputDirectory = CommandLine.arguments.dropFirst().first,
      !rawOutputDirectory.isEmpty
else {
    FileHandle.standardError.write(Data("Usage: generate-app-icon.swift <output-directory>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: rawOutputDirectory)

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(name: String, pixels: Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-1024.png", 1024),
]

for variant in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: variant.pixels,
        pixelsHigh: variant.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
        xRadius: 220,
        yRadius: 220
    )
    NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.12, alpha: 1).setFill()
    tile.fill()

    let bubble = NSBezierPath(
        roundedRect: NSRect(x: 176, y: 246, width: 672, height: 560),
        xRadius: 96,
        yRadius: 96
    )
    NSColor(calibratedRed: 0.09, green: 0.80, blue: 0.94, alpha: 1).setStroke()
    bubble.lineWidth = 38
    bubble.stroke()

    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 374, y: 258))
    tail.line(to: NSPoint(x: 292, y: 164))
    tail.line(to: NSPoint(x: 462, y: 250))
    tail.lineCapStyle = .round
    tail.lineJoinStyle = .round
    tail.lineWidth = 38
    tail.stroke()

    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 266, y: 566, width: 492, height: 76),
        xRadius: 38,
        yRadius: 38
    ).fill()
    NSBezierPath(
        roundedRect: NSRect(x: 266, y: 410, width: 366, height: 76),
        xRadius: 38,
        yRadius: 38
    ).fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: outputDirectory.appending(path: variant.name), options: .atomic)
}
