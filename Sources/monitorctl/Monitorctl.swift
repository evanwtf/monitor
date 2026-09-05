import ArgumentParser
import Foundation
import MonitorCore
import MonitorSources

// A headless harness for the sampling code.
//
// Sampling is the part most likely to be wrong, and the GUI is the worst place
// to find out. Every source can be read, listed and watched from here without
// launching a window, which makes a broken reader a one-line command rather
// than a debugging session.
//
// The parsing is declared rather than hand-rolled, for the reason set out in
// `monitord`'s Monitord.swift: the usage text was a literal that only a leading
// `-` reached, and an unknown flag was silently ignored (#48). `monitorctl`
// rejected an unknown *command* but not an unknown *flag*, which is the half
// that matters — a mistyped `--intrval` changes what is measured and says
// nothing.

@main
struct Monitorctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitorctl",
        abstract: "Read the system metrics that the Monitor app charts.",
        discussion: """
        Counter-derived metrics (disk, network, paging) need two readings to \
        produce a rate, so `read` prints nothing for them and `watch` prints \
        nothing on its first line. That is correct behaviour, not a failure: \
        there is no rate yet.

        Nothing here writes to disk unless you ask it to. There is no such flag \
        yet.
        """,
        version: MonitorVersion.detailed,
        subcommands: [List.self, Read.self, Watch.self]
    )
}

/// `--source`, shared by all three subcommands.
///
/// One declaration, so the known-source list in the help and the list the
/// validation checks against are the same array. They used to be a sentence in
/// a string literal and a `make(ids:)` call that returned an empty array.
struct SourceSelection: ParsableArguments {
    /// Built once. This string is interpolated into the `@Option` below, which
    /// ArgumentParser evaluates every time it initialises the type — often, and
    /// once per parameterised test.
    static let known = "Known: \(SourceRegistry.allIDs.joined(separator: ", "))"

    @Option(
        name: .customLong("source"),
        parsing: .singleValue,
        help: ArgumentHelp(
            "Limit to one source; repeatable. Default: all.",
            discussion: SourceSelection.known,
            valueName: "id"
        )
    )
    var ids: [String] = []

    func validate() throws {
        let known = Set(SourceRegistry.allIDs)
        let unknown = ids.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            throw ValidationError(
                "no such source: \(unknown.joined(separator: ", "))."
                    + " Known: \(SourceRegistry.allIDs.joined(separator: ", "))."
            )
        }
    }

    func resolve() -> [any MetricSource] {
        ids.isEmpty ? SourceRegistry.makeAll() : SourceRegistry.make(ids: ids)
    }
}

/// `--interval` and `--json`, shared by `read` and `watch`.
struct SamplingOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Sampling interval in seconds.", valueName: "sec"))
    var interval: Double = 1.0

    @Flag(help: "Emit one JSON object per sample instead of a table.")
    var json: Bool = false

    func validate() throws {
        guard interval > 0 else {
            throw ValidationError("--interval must be greater than zero, not \(interval).")
        }
    }
}

extension Monitorctl {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every source and the metrics it declares."
        )

        @OptionGroup var selection: SourceSelection

        func run() {
            for source in selection.resolve() {
                print("\(source.id)")
                for descriptor in source.descriptors {
                    print(
                        "  \(descriptor.id.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0))"
                            + " \(descriptor.group) / \(descriptor.name)"
                            + "  [\(descriptor.unit.rawValue), \(descriptor.kind.rawValue)]"
                    )
                }
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read once and print the values."
        )

        @OptionGroup var selection: SourceSelection
        @OptionGroup var sampling: SamplingOptions

        func run() async {
            let sources = selection.resolve()
            let printer = SamplePrinter(sources: sources, json: sampling.json)
            let sampler = Sampler(sources: sources, sinks: [], interval: sampling.interval)
            // Two ticks, so counter-derived rates have a previous reading to
            // work from. Otherwise `read` would report nothing for disk and
            // network and look broken.
            _ = await sampler.tick(at: Date().timeIntervalSince1970)
            try? await Task.sleep(for: .seconds(min(sampling.interval, 1.0)))
            await printer.emit(sampler.tick(at: Date().timeIntervalSince1970))
        }
    }

    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read repeatedly until interrupted."
        )

        @OptionGroup var selection: SourceSelection
        @OptionGroup var sampling: SamplingOptions

        @Option(help: ArgumentHelp("Stop after n samples.", valueName: "n"))
        var count: Int?

        func validate() throws {
            if let count, count < 1 {
                throw ValidationError("--count must be at least 1, not \(count).")
            }
        }

        func run() async {
            let sources = selection.resolve()
            let printer = SamplePrinter(sources: sources, json: sampling.json)
            let sampler = Sampler(sources: sources, sinks: [], interval: sampling.interval)
            var taken = 0
            while count.map({ taken < $0 }) ?? true {
                let batch = await sampler.tick(at: Date().timeIntervalSince1970)
                if !batch.samples.isEmpty {
                    if !sampling.json {
                        let time = Date(timeIntervalSince1970: batch.timestamp)
                        print("— \(time.formatted(date: .omitted, time: .standard))")
                    }
                    printer.emit(batch)
                    taken += 1
                }
                try? await Task.sleep(for: .seconds(sampling.interval))
            }
        }
    }
}

/// Prints a batch as a table or as one JSON object per line.
struct SamplePrinter {
    let descriptors: [MetricID: MetricDescriptor]
    let json: Bool

    init(sources: [any MetricSource], json: Bool) {
        descriptors = Dictionary(
            sources.flatMap(\.descriptors).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in
                first
            }
        )
        self.json = json
    }

    func emit(_ batch: SampleBatch) {
        guard !batch.samples.isEmpty else { return }
        if json {
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
}
