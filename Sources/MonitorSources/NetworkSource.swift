import Darwin
import Foundation
import MonitorCore
import SystemConfiguration

/// Network throughput, summed over the machine's physical interfaces.
///
/// `getifaddrs` reports cumulative byte counts per interface, so the values are
/// differentiated into rates.
///
/// **Only real NICs are counted — Wi-Fi and wired.** This matters more than it
/// sounds. A Mac carries a crowd of interfaces that are not the network: `lo0`
/// is the machine talking to itself and swamps the chart during a build;
/// `utun0…8` are VPN and per-app tunnels, and traffic through one is counted
/// *twice* if you sum both the tunnel and the `en0` it leaves by; `awdl0` is
/// AirDrop; `llw0`, `anpi0`, `ap1` are Apple's own link-local and internal
/// interfaces. Summing everything `getifaddrs` returns therefore reports more
/// traffic than crossed the wire.
///
/// The list comes from `SCNetworkInterfaceCopyAll`, filtered to the Ethernet and
/// IEEE 802.11 types, which is the supported way to ask "what would a person
/// call a network interface on this Mac". A Thunderbolt Bridge is deliberately
/// excluded along with the tunnels: it is real hardware underneath but the
/// bridge itself is a virtual interface.
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

    /// BSD names of the physical NICs, cached.
    ///
    /// `SCNetworkInterfaceCopyAll` costs about 0.8 ms — fine occasionally,
    /// far too much at two reads a second when the whole sampling pass is
    /// supposed to come in under a millisecond. Re-resolved every
    /// `topologyInterval` so a dongle plugged in mid-session still appears.
    private var physical: Set<String> = []
    private var resolvedAt: TimeInterval?
    private static let topologyInterval: TimeInterval = 10

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
        if resolvedAt.map({ timestamp - $0 >= Self.topologyInterval }) ?? true {
            physical = try Self.physicalInterfaceNames()
            resolvedAt = timestamp
        }
        let totals = try Self.readInterfaceTotals(matching: physical)
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

    /// The BSD names of the Wi-Fi and wired interfaces on this machine.
    ///
    /// Deliberately an allow-list of interface *types* rather than a deny-list
    /// of name prefixes. A deny-list has to be extended every time Apple ships
    /// another `anpi`-style internal interface, and the failure mode of missing
    /// one is silently over-reporting traffic — the kind of wrong number nobody
    /// checks.
    static func physicalInterfaceNames() throws -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            throw MetricSourceError.readFailed("network interface list", code: 0)
        }
        var names: Set<String> = []
        for interface in all {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  type == (kSCNetworkInterfaceTypeEthernet as String)
                  || type == (kSCNetworkInterfaceTypeIEEE80211 as String),
                  let name = SCNetworkInterfaceGetBSDName(interface) as String?
            else { continue }
            names.insert(name)
        }
        return names
    }

    /// Every interface `getifaddrs` reports, physical or not. Exists so a test
    /// can show that the filter narrows the set rather than merely matching it.
    static func allInterfaceNames() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: head, next: { $0.pointee.ifa_next })
            .filter { $0.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) }
            .map { String(cString: $0.pointee.ifa_name) }
    }

    static func readInterfaceTotals(matching names: Set<String>) throws -> InterfaceTotals {
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
            guard names.contains(String(cString: interface.ifa_name)) else { continue }
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
