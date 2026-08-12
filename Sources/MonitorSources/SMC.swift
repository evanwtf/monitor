import Foundation
import IOKit
import MonitorCore

/// A connection to the System Management Controller, which is where a Mac
/// keeps its temperatures, fan speeds and power rails.
///
/// The protocol is undocumented — one `IOConnectCallStructMethod` selector and
/// a struct whose layout has to match the driver's — but it needs no
/// privileges, which the alternatives do not manage: `powermetrics` wants root
/// and IOReport is a private framework. Reads are unprivileged on every Mac
/// this has been tried on; *writes* (setting a fan speed) are the part that
/// needs root, and this type cannot write.
///
/// Separate from `SMCSource` because it is transport, not a metric: it knows
/// how to name, size and decode a key, and nothing about what any key means.
final class SMC {
    /// One SMC key with its type and size already looked up.
    ///
    /// Worth caching because reading a key costs two round trips — one to ask
    /// its type and size, one to fetch the bytes — and the type never changes
    /// while the machine is running. Halving the calls halves the cost of a
    /// tick, and a tick happens twice a second for as long as the app is open.
    struct Key {
        let code: UInt32
        let name: String
        let type: UInt32
        let size: Int
    }

    private let connection: io_connect_t

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw MetricSourceError.unavailable("AppleSMC")
        }
        defer { IOObjectRelease(service) }

        var port: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &port)
        guard result == kIOReturnSuccess else {
            throw MetricSourceError.readFailed("AppleSMC connection", code: result)
        }
        connection = port
    }

    deinit { IOServiceClose(connection) }

    // MARK: - Keys

    /// Every key whose name begins with `prefix`, in the SMC's own order.
    ///
    /// The key table is sorted, so this binary-searches for the start of the
    /// range and walks forward rather than enumerating all of it: a machine
    /// publishes a couple of thousand keys and reading every name takes about
    /// 300 ms, which is too long to spend at launch to find the 150 that are
    /// temperatures.
    func keys(withPrefix prefix: String) throws -> [Key] {
        let count = try keyCount()
        let lower = Self.code(prefix.padding(toLength: 4, withPad: "\0", startingAt: 0))
        // The end of the range is the same prefix with its last character
        // stepped on, so "T" scans up to but not including "U".
        var upperPrefix = Array(prefix.utf8)
        upperPrefix[upperPrefix.count - 1] += 1
        let upper = Self.code(String(decoding: upperPrefix, as: UTF8.self)
            .padding(toLength: 4, withPad: "\0", startingAt: 0))

        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            guard let code = try? key(atIndex: middle) else { break }
            if code < lower { low = middle + 1 } else { high = middle }
        }

        var found: [Key] = []
        var index = low
        while index < count, let code = try? key(atIndex: index), code < upper {
            if let key = try? info(for: code) { found.append(key) }
            index += 1
        }
        return found
    }

    /// A single key by name, or nil if this machine does not publish it.
    func key(named name: String) -> Key? {
        try? info(for: Self.code(name))
    }

    private func keyCount() throws -> Int {
        guard let key = try? info(for: Self.code("#KEY")),
              let value = try? readRaw(key)
        else { throw MetricSourceError.unavailable("SMC key count") }
        return Int(value.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private func key(atIndex index: Int) throws -> UInt32 {
        var input = SMCParameters()
        input.data8 = Self.commandKeyFromIndex
        input.data32 = UInt32(index)
        guard let output = call(input) else {
            throw MetricSourceError.readFailed("SMC key index \(index)", code: 0)
        }
        return output.key
    }

    private func info(for code: UInt32) throws -> Key {
        var input = SMCParameters()
        input.key = code
        input.data8 = Self.commandKeyInfo
        guard let output = call(input) else {
            throw MetricSourceError.unavailable("SMC key \(Self.name(code))")
        }
        return Key(
            code: code,
            name: Self.name(code),
            type: output.keyInfo.dataType,
            size: Int(output.keyInfo.dataSize)
        )
    }

    // MARK: - Reading

    /// A key's current value, converted to a plain number by its SMC type.
    ///
    /// Returns nil for a type this does not know how to decode rather than
    /// guessing: the types are a fixed-point zoo — `sp78` on Intel, `flt` on
    /// Apple silicon, `fpe2` for fan speeds — and reading one as another
    /// produces a number that looks like a temperature and is not.
    func value(of key: Key) -> Double? {
        guard let bytes = try? readRaw(key) else { return nil }
        switch Self.name(key.type) {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            // Little-endian, unlike every integer type the SMC reports.
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8", "ui16", "ui32", "ui64":
            return Double(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        case "si8", "si16":
            var value: Int64 = 0
            for byte in bytes { value = value << 8 | Int64(byte) }
            return Double(value)
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }

    private func readRaw(_ key: Key) throws -> [UInt8] {
        var input = SMCParameters()
        input.key = key.code
        input.data8 = Self.commandReadKey
        input.keyInfo.dataSize = IOByteCount32(key.size)
        input.keyInfo.dataType = key.type
        guard let output = call(input) else {
            throw MetricSourceError.readFailed("SMC key \(key.name)", code: 0)
        }
        let size = max(0, min(32, key.size))
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
    }

    private func call(_ input: SMCParameters) -> SMCParameters? {
        var input = input
        var output = SMCParameters()
        var size = MemoryLayout<SMCParameters>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.selectorHandleEvent,
            &input, MemoryLayout<SMCParameters>.stride, &output, &size
        )
        // `result` is the kernel's verdict on the call; `output.result` is the
        // SMC's own on the key, and a missing key fails only in the second.
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Four-character codes

    /// SMC keys and types are four-character codes packed into a `UInt32`.
    static func code(_ name: String) -> UInt32 {
        name.unicodeScalars.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1.value) }
    }

    static func name(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF),
                     UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes.filter { $0 != 0 }, encoding: .ascii) ?? ""
        // Type codes are space-padded ("flt "), key names are not.
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The wire format

    /// The one user-client selector the SMC exposes; the command lives in the
    /// struct's `data8` field rather than in the selector.
    private static let selectorHandleEvent: UInt32 = 2
    private static let commandReadKey: UInt8 = 5
    private static let commandKeyFromIndex: UInt8 = 8
    private static let commandKeyInfo: UInt8 = 9

    /// Must match the driver's struct byte for byte. The names are the ones
    /// used in Apple's own SMC sample code, kept so the layout can be checked
    /// against it.
    private struct SMCParameters {
        var key: UInt32 = 0
        var versionMajor: UInt8 = 0
        var versionMinor: UInt8 = 0
        var versionBuild: UInt8 = 0
        var versionReserved: UInt8 = 0
        var versionRelease: UInt16 = 0
        var limitVersion: UInt16 = 0
        var limitLength: UInt16 = 0
        var limitCPU: UInt32 = 0
        var limitGPU: UInt32 = 0
        var limitMemory: UInt32 = 0
        var keyInfo = SMCKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private struct SMCKeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
}
