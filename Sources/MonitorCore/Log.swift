import OSLog

/// One logger for the whole package. `os.Logger` rather than `print` so the
/// output is available in Console.app and survives a release build.
public let log = Logger(subsystem: "wtf.evan.monitor", category: "monitor")
