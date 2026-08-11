# Writing a source

A source is one file in `Sources/MonitorSources/`, conforming to `MetricSource`.

```swift
public final class ThermalSource: MetricSource, @unchecked Sendable {
    public let id = "thermal"

    public static let cpuTemperature = MetricID("thermal.cpu")

    public var descriptors: [MetricDescriptor] {
        [MetricDescriptor(
            id: Self.cpuTemperature, name: "CPU", group: "Temperature",
            unit: .celsius)]
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        guard let celsius = readSensor() else {
            throw MetricSourceError.unavailable("thermal sensors")
        }
        return SampleBatch(timestamp: timestamp, values: [Self.cpuTemperature: celsius])
    }
}
```

Then add it to `SourceRegistry.makeAll()`. That single list feeds the app, the
CLI and the tests — nothing else needs wiring.

## Rules

**Throw; never return zeros.** This is the one that matters most. If a failed
read returns 0, a broken sensor looks exactly like an idle machine, and a
monitoring tool that quietly reports "everything is fine" when it has actually
gone blind is worse than one that crashes. Throw `MetricSourceError` and the UI
greys the card out and says the metric is unavailable.

**Declare descriptors up front**, before any data exists, so the window can lay
itself out at launch. Returning an empty array is legitimate on a machine
without the hardware.

**Be quick.** `read(at:)` runs on the sampler's task on every tick. Anything
slow belongs behind a cache.

**Use `RateTracker` for cumulative counters.** Do not differentiate by hand. It
returns nil for the first reading — there is no rate yet, and reporting zero
would draw a dip that did not happen — and it skips intervals where a counter
goes backwards, which means a wrap or a replaced device rather than a real
negative rate.

**Pick unit and kind first.** They determine the axis, the formatting, and
whether the value needs differentiating. Getting them wrong yields a chart that
is quietly wrong rather than obviously broken.

## Testing a source

Source tests run against the real machine, because there is nothing meaningful
to mock: the entire job of a source is to read *this* Mac correctly.

So they assert shape and plausible range rather than values — a fraction is
within 0...1, a rate is not negative, memory in use does not exceed physical
RAM. A source allowed to be unavailable (GPU) is tested to either produce a
plausible value or throw `.unavailable`, and specifically not to invent a
number.

## Developing without the GUI

```sh
swift run monitorctl list
swift run monitorctl read --source disk
swift run monitorctl watch --source disk --interval 0.5 --count 20
swift run monitorctl watch --json | jq '.["disk.bytes.written"]'
```

Sampling is the part most likely to be wrong and the GUI is the worst place to
find that out. Get a source right in the CLI first.
