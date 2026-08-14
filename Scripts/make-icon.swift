#!/usr/bin/env swift
//
// Draw the app icon, then build AppIcon.icns from it.
//
// Usage:
//   swift Scripts/make-icon.swift <output.icns>
//
// The icon is drawn rather than stored, for the same reason the rest of the
// panel is: every colour in it comes from the same palette the app uses, so a
// change to the theme cannot leave the icon behind. It also keeps a binary
// blob out of the repository — the source is the drawing.
//
// The subject is one dial. Not a chart, not a stack of them: at 32 points a
// chart is grey fuzz, while a needle at an angle survives all the way down to
// the 16-point menu size, which is the size that decides whether an icon
// works.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
//
// Theme.swift is the original. These are the same values; the script cannot
// import MonitorUI because it runs before anything is built.

let background = (top: (0.16, 0.16, 0.19), bottom: (0.055, 0.055, 0.07))
let dialFace = (0.16, 0.16, 0.17)
let bezelLight = 0.42, bezelDark = 0.16
let tickColour = (0.72, 0.72, 0.72)
let needleColour = (0.16, 0.68, 0.96)
let redline = (0.85, 0.20, 0.16)
let lcd = (1.00, 0.71, 0.24)

func rgb(_ c: (Double, Double, Double), _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
}

// MARK: - Shape

/// A superellipse, which is what a macOS icon's outline actually is.
///
/// `CGPath(roundedRect:)` draws circular corners. Next to any other icon in
/// the Dock that reads as slightly wrong — the corners bulge where Apple's
/// taper. Five is the exponent that matches closely enough at icon sizes.
func squirclePath(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let power = 2 / exponent
        let x = cx + a * copysign(pow(abs(cosT), power), cosT)
        let y = cy + b * copysign(pow(abs(sinT), power), sinT)
        step == 0 ? path.move(to: CGPoint(x: x, y: y))
            : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

/// The dial sweeps 270°, from lower left round to lower right, and the needle
/// sits at 62% of that — high enough to read as "under load" rather than
/// broken or idle, and clear of both the vertical and the diagonal, where a
/// needle looks like an accident of alignment.
let sweepStart = 225.0, sweepEnd = -45.0
let needleFraction = 0.62

func angle(_ fraction: Double) -> Double {
    (sweepStart + (sweepEnd - sweepStart) * fraction) * .pi / 180
}

func draw(size: Double, into context: CGContext) {
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    context.setFillColor(CGColor(gray: 0, alpha: 0))
    context.fill(full)

    // Apple's icon grid leaves the outer tenth of the canvas empty, so the
    // shape below is what people actually see as "the icon".
    let inset = size * 0.09
    let body = full.insetBy(dx: inset, dy: inset)
    let shape = squirclePath(in: body)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(background.bottom), rgb(background.top)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: body.minY),
        end: CGPoint(x: 0, y: body.maxY),
        options: []
    )
    context.restoreGState()

    // A hairline along the top edge: the same trick a physical panel plays,
    // where the bevel catches the light from above.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.13))
    context.setLineWidth(max(1, size * 0.006))
    context.strokePath()
    context.restoreGState()

    let centre = CGPoint(x: full.midX, y: full.midY - size * 0.02)
    let radius = size * 0.30

    // Bezel, then face. Two filled circles rather than a stroked ring, so the
    // gradient runs across the bezel the way `Theme.bezel` does in the app.
    context.saveGState()
    let bezelWidth = radius * 0.11
    let bezelRect = CGRect(
        x: centre.x - radius - bezelWidth, y: centre.y - radius - bezelWidth,
        width: (radius + bezelWidth) * 2, height: (radius + bezelWidth) * 2
    )
    context.addEllipse(in: bezelRect)
    context.clip()
    let bezelGradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(gray: bezelLight, alpha: 1),
            CGColor(gray: bezelDark, alpha: 1),
            CGColor(gray: bezelLight * 0.8, alpha: 1),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        bezelGradient,
        start: CGPoint(x: bezelRect.minX, y: bezelRect.maxY),
        end: CGPoint(x: bezelRect.maxX, y: bezelRect.minY),
        options: []
    )
    context.restoreGState()

    context.setFillColor(rgb(dialFace))
    context.fillEllipse(
        in: CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))

    // The lit arc: how far the needle has travelled, in the amber of the
    // readout. It is the one warm colour on the panel and the thing that makes
    // the icon legible when it is 16 points wide and the needle is two pixels.
    context.saveGState()
    context.setStrokeColor(rgb(lcd))
    context.setLineWidth(radius * 0.13)
    context.setLineCap(.butt)
    context.addArc(
        center: centre, radius: radius * 0.86,
        startAngle: angle(0), endAngle: angle(needleFraction),
        clockwise: true
    )
    context.strokePath()
    context.restoreGState()

    // Ticks. Nine of them, the last two in redline red. Minor ticks are left
    // out on purpose: below 128 points they close up into a grey band.
    context.setLineCap(.butt)
    for index in 0...8 {
        let fraction = Double(index) / 8
        let theta = angle(fraction)
        let outer = radius * 0.70, inner = radius * 0.57
        context.setStrokeColor(rgb(fraction > 0.76 ? redline : tickColour))
        context.setLineWidth(radius * 0.075)
        context.move(to: CGPoint(
            x: centre.x + cos(theta) * outer, y: centre.y + sin(theta) * outer))
        context.addLine(to: CGPoint(
            x: centre.x + cos(theta) * inner, y: centre.y + sin(theta) * inner))
        context.strokePath()
    }

    // The needle: a tapered blade, wide at the hub and pointed at the tip, so
    // which end is which survives being three pixels long.
    let theta = angle(needleFraction)
    let tip = CGPoint(
        x: centre.x + cos(theta) * radius * 0.49,
        y: centre.y + sin(theta) * radius * 0.49
    )
    let halfWidth = radius * 0.085
    let side = theta + .pi / 2
    let tail = radius * 0.16
    context.setFillColor(rgb(needleColour))
    context.beginPath()
    context.move(to: tip)
    context.addLine(to: CGPoint(
        x: centre.x + cos(side) * halfWidth - cos(theta) * tail,
        y: centre.y + sin(side) * halfWidth - sin(theta) * tail
    ))
    context.addLine(to: CGPoint(
        x: centre.x - cos(side) * halfWidth - cos(theta) * tail,
        y: centre.y - sin(side) * halfWidth - sin(theta) * tail
    ))
    context.closePath()
    context.fillPath()

    // Hub.
    let hub = radius * 0.13
    context.setFillColor(CGColor(gray: 0.86, alpha: 1))
    context.fillEllipse(
        in: CGRect(x: centre.x - hub, y: centre.y - hub, width: hub * 2, height: hub * 2))
}

// MARK: - Output

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(size: Double(size), into: context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("cannot encode \(url.path)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift Scripts/make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

do {
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("monitor-icon-\(getpid()).iconset")
    try? FileManager.default.removeItem(at: work)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // The names are `iconutil`'s, not a choice: it reads the set by filename.
    for base in [16, 32, 128, 256, 512] {
        try writePNG(
            render(size: base),
            to: work.appendingPathComponent("icon_\(base)x\(base).png"))
        try writePNG(
            render(size: base * 2),
            to: work.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }

    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", work.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw Failure("iconutil failed (\(iconutil.terminationStatus))")
    }

    try? FileManager.default.removeItem(at: work)
    print("Wrote \(output.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
