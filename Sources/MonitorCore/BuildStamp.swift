import Foundation

/// Which build this is: the commit it came from, and when it was made.
///
/// Two facts that answer one question — "am I looking at the change I just
/// made?" — and the answer is worth having on screen rather than in an About
/// panel two clicks away. A monitor gets left running for days, and the copy on
/// screen is very often not the copy just built.
///
/// The two are sourced differently on purpose.
///
/// **The commit is stamped at build time** by the `StampCommit` plugin, which
/// runs `git describe` before every build and writes `CommitStamp`. It has to
/// be captured then: a running program has no other way to know, and a
/// checked-in constant is a thing somebody has to remember to update, which
/// means a title bar that eventually lies.
///
/// **The build time is read at runtime** from the executable's own modification
/// date. It could have been stamped too, and stamping it would have been worse:
/// the build time changes on every build by definition, so writing it into a
/// source file would recompile `MonitorCore` every time and cost the fast
/// `swift run` loop for a fact the filesystem already knows.
public enum BuildStamp {
    /// The commit, as `git describe --tags --always --dirty` saw it:
    /// `v1.4.0-4-ga8e8631` on a branch, `v1.4.0` on a release, and either with
    /// `-dirty` appended when the tree had uncommitted changes.
    ///
    /// The `-dirty` half is the point of using `describe` rather than a bare
    /// hash. A build with uncommitted changes is not the commit it names, and a
    /// title bar claiming otherwise is the quiet kind of wrong this app is
    /// supposed to be careful about.
    public static let commit = CommitStamp.describe

    /// When the executable was written, or nil if it cannot be read.
    ///
    /// Nil rather than a stand-in date, for the same reason a source that
    /// fails throws instead of reporting zero: an unknown build time must not
    /// look like a real one.
    public static let built: Date? = {
        guard let url = Bundle.main.executableURL ?? executableFromArguments() else {
            return nil
        }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }()

    /// `Bundle.main.executableURL` is nil for a plain SwiftPM binary in some
    /// launch contexts, and `swift run monitor` is the loop this is most useful
    /// in — so fall back to the path the process was started with.
    private static func executableFromArguments() -> URL? {
        guard let first = CommandLine.arguments.first else { return nil }
        let url = URL(fileURLWithPath: first)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// The build time as a label: `Aug 28 09:12`.
    ///
    /// The date as well as the clock, always. A bare time is ambiguous the
    /// moment the window has been open overnight, which is exactly when
    /// somebody looks at this to ask whether the app is stale. A fixed POSIX
    /// format rather than the reader's locale, because this is a build
    /// identifier that gets pasted into an issue, not a date being presented.
    public static func builtLabel(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    /// Both facts on one line, for the title bar.
    public static var label: String { label(commit: commit, built: built) }

    /// The line itself, with its inputs handed over so it can be tested without
    /// rebuilding the app to change them.
    ///
    /// An unreadable build time drops out and leaves the commit alone. Half an
    /// answer beats a stand-in date that looks like the other half.
    static func label(commit: String, built: Date?, timeZone: TimeZone = .current) -> String {
        guard let built else { return commit }
        return "\(commit) · \(builtLabel(built, timeZone: timeZone))"
    }
}
