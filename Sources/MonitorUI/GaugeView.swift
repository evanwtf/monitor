import MonitorCore
import SwiftUI

/// The dial sweeps 240°, from lower left to lower right, leaving the bottom
/// open for the readout. A full 360° dial has no unambiguous zero.
private let dialStart = Angle(degrees: 150)
private let dialSweep = Angle(degrees: 240)
/// Fraction of the sweep marked as redline.
private let redlineStart = 0.8

/// The needle, as a `Shape`.
///
/// This is a `Shape` and not part of the `Canvas` for one specific reason:
/// `Canvas` draws imperatively from whatever the closure reads, so SwiftUI
/// cannot interpolate it and the needle jumps once per sample — at a one-second
/// sampling rate the gauge visibly runs at 1 fps. A `Shape` with
/// `animatableData` is interpolated by SwiftUI at the display refresh rate, so
/// the needle sweeps between readings instead of teleporting.
///
/// The face behind it stays in a `Canvas`, because ticks and labels do not move.
struct NeedleShape: Shape {
    /// Position on the dial, 0...1.
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = dialStart + Angle(degrees: dialSweep.degrees * min(1, max(0, fraction)))

        func point(_ distance: Double) -> CGPoint {
            CGPoint(
                x: center.x + distance * cos(angle.radians),
                y: center.y + distance * sin(angle.radians)
            )
        }

        var path = Path()
        // A short tail past the hub so the needle reads as balanced on a pivot
        // rather than as a line growing out of a dot.
        path.move(to: point(-radius * 0.12))
        path.addLine(to: point(radius * 0.78))
        return path
    }
}

/// The recent-peak marker, animatable for the same reason as the needle.
struct PeakMarkShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = dialStart + Angle(degrees: dialSweep.degrees * min(1, max(0, fraction)))

        func point(_ distance: Double) -> CGPoint {
            CGPoint(
                x: center.x + distance * cos(angle.radians),
                y: center.y + distance * sin(angle.radians)
            )
        }

        var path = Path()
        path.move(to: point(radius * 0.64))
        path.addLine(to: point(radius * 0.84))
        return path
    }
}

/// An analog gauge: bezel, tick arc, redline, needle, and a digital readout
/// inset in the face.
///
/// The needle carries the reading you glance at; the inset carries the reading
/// you actually quote. Both are needed — a dial alone cannot tell you 480 from
/// 520 MB/s, and a number alone gives no sense of "near the top of what this
/// disk does", which is the whole reason to draw a dial.
public struct GaugeView: View {
    public let title: String
    public let value: Double
    public let fullScale: Double
    /// Highest value seen recently, drawn as a thin memory mark on the arc.
    public let peak: Double?
    public let unit: MetricUnit
    /// How long the needle takes to reach a new reading.
    ///
    /// Set to the sampling interval by the caller, so the needle is still
    /// travelling when the next sample lands and the motion is continuous
    /// rather than a twitch followed by three-quarters of a second of nothing.
    /// The cost is that the needle trails the true value by up to one interval,
    /// which is the correct trade for an instrument you read at a glance.
    public var travelTime: TimeInterval = 1.0

    public init(
        title: String,
        value: Double,
        fullScale: Double,
        peak: Double? = nil,
        unit: MetricUnit,
        travelTime: TimeInterval = 1.0
    ) {
        self.title = title
        self.value = value
        self.fullScale = fullScale
        self.peak = peak
        self.unit = unit
        self.travelTime = travelTime
    }

    private var fraction: Double {
        guard fullScale > 0 else { return 0 }
        return min(1, max(0, value / fullScale))
    }

    private var peakFraction: Double {
        guard let peak, fullScale > 0 else { return 0 }
        return min(1, max(0, peak / fullScale))
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2

            ZStack {
                // Static face: bezel, ticks, labels, redline. Redrawn only when
                // full scale changes, not on every sample.
                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    drawBezel(context: context, center: center, radius: radius)
                    drawTicks(context: context, center: center, radius: radius)
                    drawRedline(context: context, center: center, radius: radius)
                }

                if peak != nil {
                    PeakMarkShape(fraction: peakFraction)
                        .stroke(Theme.readout.opacity(0.55), lineWidth: 1.5)
                        .animation(.easeOut(duration: travelTime), value: peakFraction)
                }

                NeedleShape(fraction: fraction)
                    .stroke(
                        Theme.needle,
                        style: StrokeStyle(lineWidth: max(2, radius * 0.045), lineCap: .round)
                    )
                    .animation(.easeOut(duration: travelTime), value: fraction)

                hub(radius: radius)
                readout(radius: radius)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Format.value(value, unit: unit))
    }

    // MARK: - Moving parts

    private func hub(radius: Double) -> some View {
        Circle()
            .fill(Color(white: 0.30))
            .overlay(Circle().strokeBorder(Color(white: 0.50), lineWidth: 1))
            .frame(width: radius * 0.2, height: radius * 0.2)
    }

    /// The digital inset: seven-segment digits over a recessed panel, with the
    /// unit spelled out underneath in ordinary type because "Mbit/s" is not
    /// expressible in seven segments.
    ///
    /// Wide, because the field is fixed at `xxxx.yy` — six cells whether or not
    /// the value needs them, so the decimal point never moves. That is most of
    /// the width of the dial face, which is why the dial's own label sits under
    /// the dial rather than on it.
    ///
    /// There is no `.contentTransition(.numericText())` here, unlike the type
    /// this replaced. `Canvas` draws imperatively from what its closure reads,
    /// so SwiftUI cannot interpolate between two readings — and a display
    /// pretending to be an LCD should snap to its new value anyway. The needle
    /// beside it carries the continuity.
    private func readout(radius: Double) -> some View {
        VStack(spacing: radius * 0.01) {
            SevenSegmentText(Format.readout(value, unit: unit))
                .frame(width: radius * 0.80, height: radius * 0.16)
            Text(Format.unitLabel(value, unit: unit))
                .font(.system(size: radius * 0.085, design: .rounded))
                .foregroundStyle(Theme.label)
        }
        .frame(width: radius * 0.86, height: radius * 0.32)
        .background(Theme.lcdPanel, in: RoundedRectangle(cornerRadius: radius * 0.05))
        .overlay(
            RoundedRectangle(cornerRadius: radius * 0.05)
                .strokeBorder(Color(white: 0.30), lineWidth: 1)
        )
        .offset(y: radius * 0.50)
    }

    // MARK: - Static face

    private func point(
        _ center: CGPoint, _ radius: Double, _ angle: Angle
    ) -> CGPoint {
        CGPoint(
            x: center.x + radius * cos(angle.radians),
            y: center.y + radius * sin(angle.radians)
        )
    }

    private func drawBezel(context: GraphicsContext, center: CGPoint, radius: Double) {
        let outer = Path(
            ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
        )
        context.fill(outer, with: .color(Theme.panelEdge))
        context.stroke(outer, with: .color(Color(white: 0.45)), lineWidth: 1)

        let faceRadius = radius * 0.9
        let face = Path(
            ellipseIn: CGRect(
                x: center.x - faceRadius, y: center.y - faceRadius,
                width: faceRadius * 2, height: faceRadius * 2
            )
        )
        context.fill(
            face,
            with: .radialGradient(
                Gradient(colors: [Theme.dialFace, Color(red: 0.09, green: 0.09, blue: 0.10)]),
                center: center, startRadius: 0, endRadius: faceRadius
            )
        )
    }

    private func drawTicks(context: GraphicsContext, center: CGPoint, radius: Double) {
        // Ten major divisions: full scale is always a 1, 2 or 5 decade, so ten
        // divisions always land on readable numbers.
        let majors = 10
        for index in 0...majors {
            let fraction = Double(index) / Double(majors)
            let tickAngle = dialStart + Angle(degrees: dialSweep.degrees * fraction)
            let outer = radius * 0.82
            let inner = radius * (index % 5 == 0 ? 0.66 : 0.72)

            var path = Path()
            path.move(to: point(center, inner, tickAngle))
            path.addLine(to: point(center, outer, tickAngle))
            context.stroke(
                path,
                with: .color(index % 5 == 0 ? Theme.tick : Theme.tickMinor),
                lineWidth: index % 5 == 0 ? 2 : 1
            )
        }

        // Label only the ends and the middle. A dial labelled at every tick is
        // a table with a needle on it.
        //
        // 0.54 rather than further out because the end labels sit at the lower
        // left and lower right, where the readout is: at 0.62 they ran under it,
        // and the fixed `xxxx.yy` field is too wide to give the horizontal room
        // back. Here they clear it vertically instead.
        for fraction in [0.0, 0.5, 1.0] {
            let labelAngle = dialStart + Angle(degrees: dialSweep.degrees * fraction)
            let text = Text(Format.tickLabel(fullScale * fraction, unit: unit))
                .font(.system(size: max(8, radius * 0.09), design: .rounded))
                .foregroundStyle(Theme.label)
            context.draw(text, at: point(center, radius * 0.54, labelAngle))
        }
    }

    private func drawRedline(context: GraphicsContext, center: CGPoint, radius: Double) {
        var path = Path()
        path.addArc(
            center: center,
            radius: radius * 0.77,
            startAngle: dialStart + Angle(degrees: dialSweep.degrees * redlineStart),
            endAngle: dialStart + dialSweep,
            clockwise: false
        )
        context.stroke(path, with: .color(Theme.redline), lineWidth: radius * 0.06)
    }
}

#Preview {
    HStack(spacing: 24) {
        GaugeView(
            title: "Disk Write", value: 4_230_000, fullScale: 10_000_000,
            peak: 8_300_000, unit: .bytesPerSecond
        )
        GaugeView(
            title: "Net In", value: 92_400_000, fullScale: 100_000_000,
            peak: 96_000_000, unit: .bitsPerSecond
        )
        GaugeView(
            title: "Net Out", value: 240_000, fullScale: 10_000_000, unit: .bitsPerSecond
        )
    }
    .padding(32)
    .frame(width: 780, height: 300)
    .background(Theme.background)
}
