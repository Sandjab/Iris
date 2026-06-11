#!/usr/bin/env swift
// Generates the menu-bar state icon assets for the docs (user guide + manual).
// Renders the same SF Symbols the app uses (AppDelegate.updateStatusIcon) as
// monochrome glyphs on a transparent background:
//   active = key.fill · paused = key · stopped = key.slash · connecting = key @ 45%
// Two variants per state, matching the banner.png / banner-dark.png convention:
//   menubar-<state>.png       black glyph (light backgrounds)
//   menubar-<state>-dark.png  white glyph (dark backgrounds)
// Usage: swift assets/make-menubar-icons.swift   (writes PNGs next to the script)

import AppKit

let states: [(name: String, symbol: String, alpha: CGFloat)] = [
    ("active", "key.fill", 1.0),
    ("paused", "key", 1.0),
    ("stopped", "key.slash", 1.0),
    ("connecting", "key", 0.45),
]

let variants: [(suffix: String, color: NSColor)] = [
    ("", .black),
    ("-dark", .white),
]

let canvasPx = 128
let outputDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()

func render(symbol: String, color: NSColor, alpha: CGFloat, to url: URL) throws {
    let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
    guard
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    else {
        throw NSError(
            domain: "make-menubar-icons",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "unknown SF Symbol: \(symbol)"]
        )
    }
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasPx,
            pixelsHigh: canvasPx,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else {
        throw NSError(
            domain: "make-menubar-icons",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "cannot create bitmap context"]
        )
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Fit the glyph centered with ~10% padding, preserving aspect ratio.
    let side = CGFloat(canvasPx)
    let scale = min(side * 0.8 / base.size.width, side * 0.8 / base.size.height)
    let w = base.size.width * scale
    let h = base.size.height * scale
    let frame = NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
    base.draw(in: frame, from: .zero, operation: .sourceOver, fraction: alpha)

    // Tint: sourceAtop repaints only where the glyph is, keeping its alpha mask
    // (so the 45% "connecting" dim survives the tint).
    color.set()
    NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "make-menubar-icons",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(url.lastPathComponent)"]
        )
    }
    try png.write(to: url)
    print("wrote \(url.path)")
}

for state in states {
    for variant in variants {
        let url = outputDir.appendingPathComponent("menubar-\(state.name)\(variant.suffix).png")
        do {
            try render(symbol: state.symbol, color: variant.color, alpha: state.alpha, to: url)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
