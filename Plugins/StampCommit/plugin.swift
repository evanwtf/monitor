import Foundation
import PackagePlugin

/// Writes the commit this build came from into a Swift constant.
///
/// A prebuild command, so it runs before every build and cannot go stale the
/// way a checked-in file or a manual step would. It writes only when the hash
/// has actually changed: rewriting it every build would touch a source file
/// `MonitorCore` compiles, and recompiling the whole module on every `swift
/// run` would cost the fast dev loop the README is built around.
///
/// Deliberately **not** the build time as well. That changes every build by
/// definition, so putting it here would force exactly the recompile this avoids
/// — and it can be had for nothing at runtime from the executable's own
/// modification date. See `BuildStamp` in `MonitorCore`.
@main
struct StampCommit: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target _: Target) throws -> [Command] {
        let directory = context.pluginWorkDirectoryURL
        let output = directory.appending(path: "CommitStamp.generated.swift")
        // `git describe` rather than `rev-parse`: it carries the tag when the
        // build sits on one, which is what a release should say, and falls back
        // to the short hash when it does not. `--dirty` because a build with
        // uncommitted changes is not the commit it names, and a title bar that
        // says otherwise is the quiet kind of wrong.
        let script = #"""
        set -u
        cd "$SOURCE" 2>/dev/null || exit 0
        commit=$(git describe --tags --always --dirty --abbrev=8 2>/dev/null || echo unknown)
        printf 'enum CommitStamp { static let describe = "%s" }\n' "$commit" > "$OUT.new"
        if [ -f "$OUT" ] && cmp -s "$OUT" "$OUT.new"; then
            rm -f "$OUT.new"
        else
            mv "$OUT.new" "$OUT"
        fi
        """#
        return [
            .prebuildCommand(
                displayName: "Stamping the commit",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                environment: [
                    "SOURCE": context.package.directoryURL.path(),
                    "OUT": output.path(),
                ],
                outputFilesDirectory: directory
            ),
        ]
    }
}
