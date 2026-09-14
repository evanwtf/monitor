// swift-tools-version: 6.0
import PackageDescription

// A standalone macOS system monitor. Not a menu-bar extra: the whole point is a
// window with charts big enough to read.
//
//   MonitorCore     metric model, time series, gauge scaling — no macOS APIs
//   MonitorSources  the macOS-specific readers (mach, IOKit, sysctl)
//   MonitorUI       SwiftUI dashboard
//   monitor         the app
//   monitorctl      headless CLI — develop and verify sources without the GUI
//   MonitorLog      the rotating CSV writer behind monitord
//   monitord        headless daemon — logs every metric to rotating CSV
//   MonitorStore    on-disk history — designed and tested, deliberately NOT
//                   linked into v1; see below
//
// MonitorCore deliberately knows nothing about macOS so the time-series,
// downsampling and gauge-scaling logic is testable on its own, without a
// machine to read.
//
// **v1 writes nothing to disk.** `monitor` does not depend on `MonitorStore`,
// so there is no code path in the app that can touch the filesystem — a
// property the dependency graph enforces rather than a rule someone has to
// remember. A monitor is a program that runs all day forever, and a careless
// one costs real SSD endurance for data nobody reads. `MonitorStore` exists
// because persistence is coming, and its retention design is worth having
// settled early, but linking it into the app is a deliberate later decision.
// `docs/storage.md` works through the write-amplification arithmetic.

let package = Package(
    name: "monitor",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        .library(name: "MonitorSources", targets: ["MonitorSources"]),
        .library(name: "MonitorStore", targets: ["MonitorStore"]),
        .library(name: "MonitorUI", targets: ["MonitorUI"]),
        .library(name: "MonitorLog", targets: ["MonitorLog"]),
        .library(name: "MonitorPrometheus", targets: ["MonitorPrometheus"]),
        .executable(name: "monitor", targets: ["monitor"]),
        .executable(name: "monitorctl", targets: ["monitorctl"]),
        .executable(name: "monitord", targets: ["monitord"]),
    ],
    dependencies: [
        // The only third-party dependency, and it is Apple's. Both CLIs used to
        // hand-roll their parsing, which is how `monitord --help` came to start
        // the daemon instead of printing usage (#48). Help generated from the
        // flag declarations cannot drift from the flags.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MonitorCore", plugins: ["StampCommit"]),
        // A prebuild plugin, so the commit in the title bar cannot go stale the
        // way a checked-in constant or a manual step would. It rewrites its
        // output only when the hash changes, which is what keeps `swift run`
        // from recompiling MonitorCore every time.
        .plugin(name: "StampCommit", capability: .buildTool()),
        .target(name: "MonitorSources", dependencies: ["MonitorCore"]),
        .target(name: "MonitorStore", dependencies: ["MonitorCore"]),
        // The rotating CSV logger. `monitord` writes it; the app never links it,
        // so the app still has no code path that reaches the filesystem.
        .target(name: "MonitorLog", dependencies: ["MonitorCore"]),
        // The Prometheus exposition-format renderer and the sensor-metric
        // mapping. Pure MonitorCore, no macOS APIs and no new dependency, so
        // the format is a golden-file test rather than a hand-rolled printer
        // nobody checks. Read by monitor-exporter.
        .target(name: "MonitorPrometheus", dependencies: ["MonitorCore"]),
        // Note the absence of MonitorStore in the next three targets. That is
        // the point, not an oversight.
        .target(name: "MonitorUI", dependencies: ["MonitorCore", "MonitorSources"]),
        .executableTarget(name: "monitor", dependencies: ["MonitorUI"]),
        .executableTarget(
            name: "monitorctl",
            dependencies: [
                "MonitorCore", "MonitorSources",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "monitord",
            dependencies: [
                "MonitorLog", "MonitorSources",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
        .testTarget(
            name: "MonitorSourcesTests",
            dependencies: ["MonitorSources", "MonitorCore"]),
        .testTarget(name: "MonitorStoreTests", dependencies: ["MonitorStore", "MonitorCore"]),
        .testTarget(name: "MonitorLogTests", dependencies: ["MonitorLog", "MonitorCore"]),
        // The renderer's format is golden-file tested; the mapping is tested
        // against the real SMCSource/GPUSource MetricID constants, so a renamed
        // id breaks the test rather than the exporter silently dropping a metric.
        .testTarget(
            name: "MonitorPrometheusTests",
            dependencies: ["MonitorPrometheus", "MonitorCore", "MonitorSources"]),
        // The two CLIs' argument parsing. The bug that motivated it (#48) was
        // invisible to every other suite: both binaries built, ran and sampled
        // correctly, and only their front doors were wrong.
        .testTarget(
            name: "CommandLineTests",
            dependencies: [
                "monitorctl", "monitord", "MonitorCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        // AppModel decides what the panel draws and which sources are read on
        // a given tick. Both are arithmetic, and both are wrong in ways that
        // look like a rendering glitch, so they are worth testing directly.
        .testTarget(name: "MonitorUITests", dependencies: ["MonitorUI", "MonitorCore"]),
    ]
)
