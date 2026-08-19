/// The version of the app, in one place.
///
/// The About panel reads it at runtime and `Scripts/make-app.sh` greps this
/// file for it when it writes `Info.plist`, so a bundled build and an
/// unbundled one cannot claim different versions. Keep the literal on one
/// line: the script's pattern expects it there.
public enum MonitorVersion {
    public static let string = "1.3.2"
}
