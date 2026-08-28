import Foundation

/// Turns a raw value into what a gauge or an axis shows.
///
/// Centralised because the same number appears in a gauge readout, a tick
/// label, a chart axis and `monitorctl` output, and they must agree. A gauge
/// reading 480 MB/s beside an axis reading 0.48 GB/s looks like a bug.
public enum Format {
    /// Decimal units (kB = 1000), matching how Apple reports disk and network
    /// throughput. Mixing these with binary units is where "my 500 MB/s SSD"
    /// arguments come from, so the app picks one and stays with it.
    public static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        let suffix = perSecond ? "/s" : ""
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var magnitude = abs(value)
        var index = 0
        while magnitude >= 1000, index < units.count - 1 {
            magnitude /= 1000
            index += 1
        }
        let digits = magnitude < 10 && index > 0 ? 1 : 0
        return "\(String(format: "%.\(digits)f", magnitude)) \(units[index])\(suffix)"
    }

    /// A plain count, with SI suffixes: `847`, `1.2 M`, `340 k`.
    ///
    /// Same decimal thousands and the same digit rule as `bytes`, because the
    /// two sit beside each other in a legend and a pair of counts that disagree
    /// about what "k" means is worse than either. A packet total is seven
    /// figures on a busy minute, and `1234567` is unreadable at a glance and
    /// far too wide for the slot it has to sit in.
    public static func count(_ value: Double) -> String {
        let units = ["", " k", " M", " G", " T"]
        var magnitude = abs(value)
        var index = 0
        while magnitude >= 1000, index < units.count - 1 {
            magnitude /= 1000
            index += 1
        }
        let digits = magnitude < 10 && index > 0 ? 1 : 0
        return "\(String(format: "%.\(digits)f", magnitude))\(units[index])"
    }

    /// How much moved, from a `WindowTotal` in the rate's own base unit.
    ///
    /// Applies `MetricUnit.accumulation` and then formats the result — so the
    /// bits-to-bytes conversion happens in exactly one place on the way to the
    /// screen, which is what stops a header and anything downstream disagreeing
    /// about whether 1.4 GB and 11.2 Gbit are the same reading.
    ///
    /// Nil for a unit that does not accumulate, so a caller cannot draw
    /// degree-seconds under a temperature by forgetting to check.
    public static func total(_ value: Double, unit: MetricUnit) -> String? {
        guard let accumulation = unit.accumulation else { return nil }
        let scaled = value * accumulation.scale
        switch accumulation.unit {
        case .bytes: return bytes(scaled)
        case .count: return count(scaled)
        default: return self.value(scaled, unit: accumulation.unit)
        }
    }

    /// The widest reading `total(_:unit:)` is expected to produce, for reserving
    /// layout width. A floor, exactly like `widestValue`.
    ///
    /// The legend is where this matters most: a total climbing from `88 MB` to
    /// `1.4 GB` must not shove every entry beside it sideways while it is being
    /// read.
    public static func widestTotal(unit: MetricUnit) -> String? {
        guard let accumulation = unit.accumulation else { return nil }
        switch accumulation.unit {
        case .count: return "999 M"
        default: return widestValue(unit: accumulation.unit)
        }
    }

    /// Throughput is pinned to mega-units and never rescaled: disk in MB/s,
    /// network in Mbit/s, at every magnitude, including 0.02 and 5000.
    ///
    /// Auto-scaling is right for an axis and wrong for an instrument. The unit
    /// under a needle you are watching must not change while you are reading
    /// it, and a readout of `900` is unusable until you have also read the word
    /// underneath — which is a second look, on a display whose whole purpose is
    /// to be legible in one. Pinning also stops the gauge and its own dial
    /// labels from landing in different decades.
    public static let throughputDivisor = 1_000_000.0

    /// The number part of a throughput reading, at three significant figures.
    ///
    /// Three keeps the width of the readout near-constant as the value moves —
    /// `0.02`, `2.35`, `12.4`, `245` — which matters more here than the digits
    /// given up, because the readout sits inside a fixed inset on the dial.
    public static func throughput(_ value: Double) -> String {
        let scaled = value / throughputDivisor
        if scaled >= 100 { return String(format: "%.0f", scaled) }
        if scaled >= 10 { return String(format: "%.1f", scaled) }
        return String(format: "%.2f", scaled)
    }

    public static func fraction(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    public static func rate(_ value: Double, unit: String = "/s") -> String {
        if value >= 1000 { return "\(Int(value.rounded()))\(unit)" }
        if value >= 10 { return String(format: "%.0f%@", value, unit) }
        return String(format: "%.1f%@", value, unit)
    }

    /// A sampling interval as a *setting*: "1 s", "1.5 s".
    ///
    /// Not `duration`, which formats a measurement and would render half a
    /// second as "500.0 ms". A whole number gets no decimal point, because
    /// "1.0 s" beside "1.5 s" reads as a reading rather than a choice; anything
    /// else keeps its half, which `%.0f` would round away. A picker that offers
    /// 1.5 s and then labels it 2 s is worse than one that does not offer it.
    public static func interval(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded()
            ? String(format: "%.0f s", seconds)
            : String(format: "%.1f s", seconds)
    }

    public static func duration(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        if seconds >= 0.001 { return String(format: "%.1f ms", seconds * 1000) }
        return String(format: "%.0f µs", seconds * 1_000_000)
    }

    /// Digits either side of the point in a gauge's readout: `xxxx.yy`.
    ///
    /// Four rather than three so the field cannot overflow on real hardware. An
    /// internal SSD reads at around 5000 MB/s, which a three-digit field could
    /// not show at all; 9999.99 covers that and a 10 Gbit link, so the overflow
    /// case is unreachable rather than merely handled.
    public static let readoutIntegerDigits = 4
    public static let readoutFractionDigits = 2

    /// A gauge's readout as a fixed field, right-aligned and space-padded, with
    /// the decimal point in the same place at every magnitude.
    ///
    /// The point staying put is the whole reason this is not just `throughput`.
    /// A readout you glance at is read partly by *position*: if the point slides
    /// left as the value grows, then `4.23` and `43.7` occupy the same pixels
    /// with different meanings, and you have to read all of it to know which you
    /// are looking at. Nailing the point down means the integer part always
    /// starts and ends in the same place, so the shape of the number carries its
    /// magnitude.
    ///
    /// Padded with spaces rather than zeros: `0004.23` reads as a part number.
    public static func readout(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytesPerSecond, .bitsPerSecond:
            let scaled = value / throughputDivisor
            let width = readoutIntegerDigits + 1 + readoutFractionDigits
            // The limit is what rounds *up* out of the field, not what exceeds
            // it: 9999.996 would print as 10000.00 and shift the point.
            let ceiling = pow(10, Double(readoutIntegerDigits))
                - 0.5 * pow(10, -Double(readoutFractionDigits))
            guard scaled >= 0, scaled < ceiling else {
                return String(repeating: "-", count: readoutIntegerDigits)
                    + "." + String(repeating: "-", count: readoutFractionDigits)
            }
            return String(format: "%\(width).\(readoutFractionDigits)f", scaled)
        default:
            return magnitude(value, unit: unit)
        }
    }

    /// The widest reading `value(_:unit:)` is expected to produce for a unit.
    ///
    /// Used to reserve layout width for a live value, so a card's header does
    /// not shift as digits come and go. Without it, a CPU series climbing from
    /// `1%` to `100%` widens its own label by two characters, every other entry
    /// in the legend slides to make room, and the whole header appears to wiggle
    /// while nothing but the number has changed.
    ///
    /// A floor rather than a cap: the caller reserves *at least* this much and
    /// a genuinely wider reading still gets drawn in full. So being wrong here
    /// costs a little jitter at an extreme, never a clipped number.
    public static func widestValue(unit: MetricUnit) -> String {
        switch unit {
        case .fraction: "100%"
        case .bytes: "999 GB"
        case .bytesPerSecond: "9999 MB/s"
        case .bitsPerSecond: "9999 Mbit/s"
        case .operationsPerSecond: "999999/s"
        case .count: "999999"
        case .hertz: "9999 Hz"
        case .celsius: "999 °C"
        case .watts: "999.9 W"
        case .rpm: "9999 rpm"
        case .seconds: "999.99 s"
        }
    }

    /// A dial's tick label, which is coarser than the readout on purpose.
    ///
    /// A tick is a landmark, not a measurement — the readout below the needle
    /// is where the digits live. On a 0–10 MB/s dial the ticks want to say
    /// 0, 5, 10, not 0.00, 5.00, 10.0, which is three characters of noise on a
    /// face with room for none.
    public static func tickLabel(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytesPerSecond, .bitsPerSecond:
            let scaled = value / throughputDivisor
            return scaled >= 1 || scaled == 0
                ? String(format: "%.0f", scaled)
                : throughput(value)
        default:
            return magnitude(value, unit: unit)
        }
    }

    /// A chart axis label: the coarse number a tick wants, plus the unit.
    ///
    /// Same reasoning as `tickLabel` — an axis is a scale, not a measurement,
    /// and the current value is spelled out in the card's header anyway. Three
    /// significant figures up the side of a chart gives `0.00 MB/s` next to
    /// `20.0 MB/s`, which reads as two different kinds of number.
    public static func axisLabel(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytesPerSecond, .bitsPerSecond:
            "\(tickLabel(value, unit: unit)) \(unitLabel(value, unit: unit))"
        default:
            self.value(value, unit: unit)
        }
    }

    /// Format a value according to its metric's unit.
    public static func value(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .fraction: fraction(value)
        case .bytes: bytes(value)
        case .bytesPerSecond, .bitsPerSecond:
            "\(throughput(value)) \(unitLabel(value, unit: unit))"
        case .operationsPerSecond: rate(value)
        case .count: rate(value, unit: "")
        case .hertz: rate(value, unit: " Hz")
        case .celsius: String(format: "%.0f °C", value)
        case .watts: String(format: "%.1f W", value)
        case .rpm: String(format: "%.0f rpm", value)
        case .seconds: duration(value)
        }
    }

    /// The unit shown under a gauge's digital readout, e.g. "MB/s". Separate
    /// from the number because the gauge draws them in different type sizes.
    public static func unitLabel(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytes:
            let text = bytes(value)
            return text.split(separator: " ").last.map(String.init) ?? ""
        case .bytesPerSecond: return "MB/s"
        case .bitsPerSecond: return "Mbit/s"
        case .fraction: return "%"
        case .operationsPerSecond: return "IO/s"
        case .seconds: return value >= 1 ? "s" : (value >= 0.001 ? "ms" : "µs")
        case .count: return ""
        case .hertz: return "Hz"
        case .celsius: return "°C"
        case .watts: return "W"
        case .rpm: return "rpm"
        }
    }

    /// The unit a value is *stored* in, for an export rather than a display.
    ///
    /// Not `unitLabel`. That one answers "what goes under the needle", and the
    /// answer there is pinned: disk always reads MB/s and network always reads
    /// Mbit/s, whatever the magnitude. The buffer holds neither — it holds
    /// bytes per second and bits per second, and a percentage is a fraction
    /// between zero and one. A CSV column headed "MB/s" carrying bytes is the
    /// quiet kind of wrong this whole file exists to prevent.
    public static func baseUnit(_ unit: MetricUnit) -> String {
        switch unit {
        case .fraction: "fraction"
        case .bytes: "B"
        case .bytesPerSecond: "B/s"
        case .bitsPerSecond: "bit/s"
        case .operationsPerSecond: "op/s"
        case .count: "count"
        case .hertz: "Hz"
        case .celsius: "°C"
        case .watts: "W"
        case .rpm: "rpm"
        case .seconds: "s"
        }
    }

    /// Just the number part, for a gauge readout whose unit is drawn separately.
    public static func magnitude(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytes:
            let text = bytes(value)
            return text.split(separator: " ").first.map(String.init) ?? "0"
        case .bytesPerSecond, .bitsPerSecond: return throughput(value)
        case .fraction: return "\(Int((value * 100).rounded()))"
        case .seconds:
            if value >= 1 { return String(format: "%.2f", value) }
            if value >= 0.001 { return String(format: "%.1f", value * 1000) }
            return String(format: "%.0f", value * 1_000_000)
        default: return rate(value, unit: "")
        }
    }
}
