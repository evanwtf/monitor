import Foundation
import MonitorCore
import MonitorSources

// A headless harness for the sampling code.
//
// Sampling is the part most likely to be wrong, and the GUI is the worst place
// to find out. Every source can be read, listed and watched from here without
// launching a window, which makes a broken reader a one-line command rather
// than a debugging session. Hand-rolled argument parsing: this has a handful of
// flags and does not need a dependency.

let usage = """
monitorctl — read the system metrics that the Monitor app charts.

USAGE
  monitorctl list                       list every source and the metrics it declares
  monitorctl read [options]             read once and print the values
  monitorctl watch [options]            read repeatedly until interrupted

OPTIONS
  --source <id>       limit to one source; repeatable. Default: all.
                      Known: \(SourceRegistry.allIDs.joined(separator: ", "))
  --interval <sec>    sampling interval for `watch` (default 1.0)
  --count <n>         stop after n samples (default: run until interrupted)
  --json              emit one JSON object per sample instead of a table

NOTES
  Counter-derived metrics (disk, network, paging) need two readings to produce
  a rate, so `read` prints nothing for them and `watch` prints nothing on its
  first line. That is correct behaviour, not a failure: there is no rate yet.

  Nothing here writes to disk unless you ask it to. There is no such flag yet.
"""

func value(for flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func values(for flag: String, in arguments: [String]) -> [String] {
    var result: [String] = []
    for (index, argument) in arguments.enumerated()
        where argument == flag && index + 1 < arguments.count
    {
        result.append(arguments[index + 1])
    }
    return result
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !command.hasPrefix("-") else {
    print(usage)
    exit(arguments.isEmpty ? 1 : 0)
}

let requested = values(for: "--source", in: arguments)
let sources = requested.isEmpty ? SourceRegistry.makeAll() : SourceRegistry.make(ids: requested)
guard !sources.isEmpty else {
    FileHandle.standardError.write(
        Data("no such source: \(requested.joined(separator: ", "))\n".utf8)
    )
    exit(1)
}

let asJSON = arguments.contains("--json")
let interval = value(for: "--interval", in: arguments).flatMap(Double.init) ?? 1.0
let limit = value(for: "--count", in: arguments).flatMap(Int.init)

let descriptors = Dictionary(
    sources.flatMap(\.descriptors).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
)

func emit(_ batch: SampleBatch) {
    guard !batch.samples.isEmpty else { return }
    if asJSON {
        var object: [String: Any] = ["timestamp": batch.timestamp]
        for sample in batch.samples { object[sample.metric.rawValue] = sample.value }
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let line = String(data: data, encoding: .utf8)
        {
            print(line)
        }
        return
    }
    for sample in batch.samples.sorted(by: { $0.metric.rawValue < $1.metric.rawValue }) {
        let unit = descriptors[sample.metric]?.unit ?? .count
        let name = sample.metric.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)
        print("  \(name) \(Format.value(sample.value, unit: unit))")
    }
}

switch command {
case "list":
    for source in sources {
        print("\(source.id)")
        for descriptor in source.descriptors {
            print(
                "  \(descriptor.id.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0))"
                    + " \(descriptor.group) / \(descriptor.name)"
                    + "  [\(descriptor.unit.rawValue), \(descriptor.kind.rawValue)]"
            )
        }
    }

case "read":
    let sampler = Sampler(sources: sources, sinks: [], interval: interval)
    // Two ticks, so counter-derived rates have a previous reading to work
    // from. Otherwise `read` would report nothing for disk and network and
    // look broken.
    let now = Date().timeIntervalSince1970
    _ = await sampler.tick(at: now)
    try? await Task.sleep(for: .seconds(min(interval, 1.0)))
    await emit(sampler.tick(at: Date().timeIntervalSince1970))

case "watch":
    let sampler = Sampler(sources: sources, sinks: [], interval: interval)
    var taken = 0
    while limit.map({ taken < $0 }) ?? true {
        let batch = await sampler.tick(at: Date().timeIntervalSince1970)
        if !batch.samples.isEmpty {
            if !asJSON {
                print(
                    "— \(Date(timeIntervalSince1970: batch.timestamp).formatted(date: .omitted, time: .standard))"
                )
            }
            emit(batch)
            taken += 1
        }
        try? await Task.sleep(for: .seconds(interval))
    }

default:
    print(usage)
    exit(1)
}
