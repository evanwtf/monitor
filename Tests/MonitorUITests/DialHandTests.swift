import AppKit
import Foundation
@testable import MonitorUI
import QuartzCore
import SwiftUI
import Testing

/// The gauge hands are turned by Core Animation, not SwiftUI (#69).
///
/// With SwiftUI animating them, a hand whose travel time equals the sampling
/// interval is always mid-sweep, so the whole panel was re-evaluated at the
/// display's refresh rate forever: 41.6% of a core at rest, against 8.3% with
/// the same sweep run by the render server. These pin the mechanism; the
/// source guard at the bottom pins the rule.
@MainActor
@Suite("DialHand")
struct DialHandTests {
    private func hosted() -> (DialHandView, NSWindow) {
        let view = DialHandView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true
        )
        window.contentView = view
        return (view, window)
    }

    private var sweep: Double {
        GaugeGeometry.dialSweep.radians
    }

    @Test("a new reading is a Core Animation sweep on the layer")
    func sweepIsALayerAnimation() throws {
        let (view, window) = hosted()
        view.turn(to: 0.5, over: 1.0, now: 0)
        let animation = try #require(view.hand.animation(forKey: "turn") as? CABasicAnimation)
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.duration == 1.0)
        #expect((animation.toValue as? Double) == sweep * 0.5)
        _ = window
    }

    @Test("an interrupted sweep starts where the hand is, not where it was going")
    func interruptionContinuesFromTheCurrentAngle() throws {
        let (view, window) = hosted()
        view.turn(to: 1.0, over: 1.0, now: 0)
        // Halfway through an ease-out, three-quarters of the way there.
        view.turn(to: 0.0, over: 1.0, now: 0.5)
        let animation = try #require(view.hand.animation(forKey: "turn") as? CABasicAnimation)
        let from = try #require(animation.fromValue as? Double)
        #expect(abs(from - sweep * 0.75) < 1e-9)
        // 180° exactly here, and past it for a larger sweep: a value read back
        // from the layer's transform would fold into ±180° and turn the long way.
        #expect(from > 0)
        _ = window
    }

    @Test("off screen the hand snaps rather than animating")
    func noWindowNoAnimation() {
        let view = DialHandView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.turn(to: 0.5, over: 1.0, now: 0)
        #expect(view.hand.animation(forKey: "turn") == nil)
    }

    @Test("the same reading twice starts nothing new")
    func unchangedValueIsIgnored() {
        let (view, window) = hosted()
        view.turn(to: 0.5, over: 1.0, now: 0)
        view.hand.removeAllAnimations()
        view.turn(to: 0.5, over: 1.0, now: 0.1)
        #expect(view.hand.animation(forKey: "turn") == nil)
        _ = window
    }

    @Test("a click passes through the hand to the tile's drag")
    func handIsNotHitTestable() {
        let (view, window) = hosted()
        #expect(view.hitTest(NSPoint(x: 50, y: 50)) == nil)
        _ = window
    }

    /// The rule that #69 broke, as a test: nothing in the panel runs a SwiftUI
    /// animation on a per-sample value. One that lasts as long as the sampling
    /// interval never stops, and SwiftUI runs it on the main thread for the
    /// whole view graph. Animate on a layer (`DialHand`) instead. The allowlist
    /// is for one-shot animations that start from a gesture and end.
    @Test("no SwiftUI animation in the panel outside the allowlist")
    func noSwiftUIAnimationOnSampledValues() throws {
        let allowed: Set = [
            "ReorderDrag.swift", // the drop indicator: 0.12 s, only during a drag
        ]
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MonitorUI")
        let files = try FileManager.default.contentsOfDirectory(atPath: ui.path)
            .filter { $0.hasSuffix(".swift") && !allowed.contains($0) }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(
                contentsOf: ui.appendingPathComponent(file),
                encoding: .utf8
            )
            let code = source.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            for line in code
                where line.contains(".animation(") || line.contains("withAnimation")
            {
                Issue.record("\(file): a SwiftUI animation (#69): \(line)")
            }
        }
    }
}

/// **Copy Image** renders a dial with `ImageRenderer`, which cannot draw the
/// live hands' layers. A copied dial must still show its needle.
@MainActor
@Suite("Gauge image")
struct GaugeImageTests {
    /// Pixels close to the needle's blue in a render of the dial.
    private func needlePixels(liveHands: Bool) throws -> Int {
        let gauge = GaugeView(
            title: "Test", value: 50, fullScale: 100, unit: .celsius, liveHands: liveHands
        )
        .frame(width: 200, height: 200)
        let renderer = ImageRenderer(content: gauge)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if c.redComponent < 0.35, c.greenComponent > 0.5, c.blueComponent > 0.8 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("a copied dial keeps its needle")
    func imageHasANeedle() throws {
        #expect(try needlePixels(liveHands: false) > 50)
    }

    @Test("the live hands are invisible to ImageRenderer, which is why copies use the shapes")
    func liveHandsDoNotRender() throws {
        #expect(try needlePixels(liveHands: true) == 0)
    }
}

/// The live hand and the still one must point the same way, or a copied dial
/// shows a different reading from the panel it was copied from. Nobody can
/// look at both at once, so this compares where their pixels land.
@MainActor
@Suite("Hand geometry")
struct HandGeometryTests {
    private static let side = 200

    /// Mean position of the needle-coloured pixels, in a y-down bitmap.
    private func centroid(_ image: CGImage) -> CGPoint? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var sum = CGPoint.zero
        var count = 0.0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.redComponent < 0.35, c.greenComponent > 0.5, c.blueComponent > 0.8
                else { continue }
                sum.x += Double(x)
                sum.y += Double(y)
                count += 1
            }
        }
        return count == 0 ? nil : CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private func still(_ fraction: Double) throws -> CGImage {
        let view = NeedleShape(fraction: fraction)
            .stroke(Theme.needle, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            .frame(width: Double(Self.side), height: Double(Self.side))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func live(_ fraction: Double) throws -> CGImage {
        let frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let view = DialHandView(frame: frame)
        view.configure(
            from: -0.12, to: 0.78, color: NSColor(Theme.needle), lineWidth: { _ in 9 },
            lineCap: .round
        )
        view.layout()
        view.turn(to: fraction, over: 0) // not in a window: snaps, no animation
        let context = try #require(CGContext(
            data: nil, width: Self.side, height: Self.side, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // No flip: Core Animation on macOS is y-up, like a bare CGContext, so
        // the layer renders the way it looks on screen, and the image's first
        // row is its top, as in the still render.
        try #require(view.layer).render(in: context)
        return try #require(context.makeImage())
    }

    @Test(
        "the live needle points where the still one does",
        arguments: [0.0, 0.25, 0.5, 0.9, 1.0]
    )
    func samePlace(fraction: Double) throws {
        let a = try #require(centroid(still(fraction)))
        let b = try #require(centroid(live(fraction)))
        #expect(abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3, "still \(a), live \(b)")
    }
}
