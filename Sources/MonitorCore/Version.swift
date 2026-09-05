/// The version of the app, in one place.
///
/// The About panel reads it at runtime and `Scripts/make-app.sh` greps this
/// file for it when it writes `Info.plist`, so a bundled build and an
/// unbundled one cannot claim different versions. Keep the literal on one
/// line: the script's pattern expects it there.
public enum MonitorVersion {
    public static let string = "1.6.0"

    /// What the app calls itself. Here beside the version because the title bar
    /// draws it, the `Window` scene names itself with it, and two spellings of
    /// one name is the sort of thing nobody notices until a screenshot.
    public static let name = "Monitor"
}

public extension MonitorVersion {
    /// What `--version` prints: the release version and the commit it was built
    /// from, on one line.
    ///
    /// Both, because they answer different questions. The version says which
    /// release this is; the commit says whether it is the change just made, and
    /// carries `-dirty` when it is not any commit at all. A CSV is more useful
    /// when its reader can say exactly which build wrote it.
    static var detailed: String { "\(string) (\(BuildStamp.commit))" }
}
