import Darwin
import Foundation
import MonitorCore

/// Network throughput, summed over every physical interface.
///
/// `getifaddrs` reports cumulative byte counts per interface, so the values are
/// differentiated into rates. Loopback is excluded — it is real traffic, but it
/// is the machine talking to itself and it swamps the chart during a build.
///
/// Throughput is reported in **bits**, not bytes. Every number anyone quotes
/// about a network is in bits — a 1 Gbit port, a 300 Mbit service, an 866 Mbit
/// Wi-Fi link — so a monitor reporting bytes makes the reader divide by eight
/// before they can tell whether the link is busy. The conversion happens here,
/// at the source, rather than in the gauge, so that the dial, the chart axis
/// and `monitorctl` cannot disagree about it.
public final class NetworkSource: MetricSource, @unchecked Sendable {
    public let id = "network"

    public static let bitsIn = MetricID("net.bits.in")
    public static let bitsOut = MetricID("net.bits.out")
    public static let packetsIn = MetricID("net.packets.in")
    public static let packetsOut = MetricID("net.packets.out")

    private var rates = RateTracker()

    public init() {}

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.bitsIn, name: "In", group: "Network", unit: .bitsPerSecond
            ),
            MetricDescriptor(
                id: Self.bitsOut, name: "Out", group: "Network", unit: .bitsPerSecond
            ),
            MetricDescriptor(
                id: Self.packetsIn, name: "Packets in", group: "Network Packets",
                unit: .operationsPerSecond
            ),
            MetricDescriptor(
                id: Self.packetsOut, name: "Packets out", group: "Network Packets",
                unit: .operationsPerSecond
            ),
        ]
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        let totals = try Self.readInterfaceTotals()
        var values: [MetricID: Double] = [:]
        // Convert the byte counters to bits before differentiating rather than
        // after. Both give the same answer, but scaling the cumulative total
        // keeps a single definition of the counter this metric tracks, and
        // `RateTracker` never sees a quantity in units the metric does not use.
        let pairs: [(MetricID, Double)] = [
            (Self.bitsIn, totals.bytesIn * 8),
            (Self.bitsOut, totals.bytesOut * 8),
            (Self.packetsIn, totals.packetsIn),
            (Self.packetsOut, totals.packetsOut),
        ]
        for (metric, total) in pairs {
            if let rate = rates.rate(for: metric, total: total, at: timestamp) {
                values[metric] = rate
            }
        }
        return SampleBatch(timestamp: timestamp, values: values)
    }

    struct InterfaceTotals {
        var bytesIn = 0.0
        var bytesOut = 0.0
        var packetsIn = 0.0
        var packetsOut = 0.0
    }

    static func readInterfaceTotals() throws -> InterfaceTotals {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else {
            throw MetricSourceError.readFailed("interface list", code: errno)
        }
        defer { freeifaddrs(head) }

        var totals = InterfaceTotals()
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            // AF_LINK carries the counters; the AF_INET entry for the same
            // interface does not, and counting both would double every byte.
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard let raw = interface.ifa_data else { continue }

            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            totals.bytesIn += Double(data.ifi_ibytes)
            totals.bytesOut += Double(data.ifi_obytes)
            totals.packetsIn += Double(data.ifi_ipackets)
            totals.packetsOut += Double(data.ifi_opackets)
        }
        return totals
    }
}
